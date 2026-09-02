package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import com.congodeveloperclub.opencongopay.sms.SensitiveOperationLease
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class MobileEnvelopeException : Exception()

private const val MOBILE_ENVELOPE_NONCE_BYTES = 24
private const val MOBILE_ENVELOPE_TAG_BYTES = 16

internal object MobileEnvelopeFormat {
    const val MAX_PAYLOAD_BYTES = 8192
    private const val DOMAIN = "openpaycongo/mobile/request-envelope/v1"

    fun plaintext(operation: String, payload: ByteArray): ByteArray {
        if (operation != "deposit" || payload.size !in 2..MAX_PAYLOAD_BYTES) throw MobileEnvelopeException()
        val value = try {
            val tokener = JSONTokener(String(payload, StandardCharsets.UTF_8))
            val parsed = tokener.nextValue() as? JSONObject ?: throw MobileEnvelopeException()
            if (tokener.nextClean().code != 0) throw MobileEnvelopeException()
            parsed
        } catch (_: MobileEnvelopeException) {
            throw MobileEnvelopeException()
        } catch (_: Exception) {
            throw MobileEnvelopeException()
        }
        return JSONObject().put("version", 1).put("operation", operation).put("payload", value)
            .toString().toByteArray(StandardCharsets.UTF_8)
    }

    fun requestAad(installationId: UUID, counter: Long): ByteArray {
        if (counter <= 0L) throw MobileEnvelopeException()
        val domain = DOMAIN.toByteArray(StandardCharsets.UTF_8)
        return ByteBuffer.allocate(2 + domain.size + 16 + 8)
            .putShort(domain.size.toShort())
            .put(domain)
            .putLong(installationId.mostSignificantBits)
            .putLong(installationId.leastSignificantBits)
            .putLong(counter)
            .array()
    }

    fun counterString(counter: Long): String {
        if (counter <= 0L) throw MobileEnvelopeException()
        return counter.toString()
    }
}

internal object MobileEnvelopeCounter {
    /** Zero is durable exhausted state after Long.MAX_VALUE was allocated. */
    fun nextAfter(allocated: Long): Long {
        if (allocated <= 0L) throw MobileEnvelopeException()
        return if (allocated == Long.MAX_VALUE) 0L else allocated + 1L
    }
}

/**
 * Narrow persistence boundary for counter reservation. The allocator is pure
 * logic: a returned counter always has its successor durably written first.
 */
internal interface MobileEnvelopeCounterStore {
    /** `null` means this installation has never reserved an envelope counter. */
    fun readNext(): Long?

    /** Throw on any uncertain or incomplete persistence outcome. */
    fun persistNext(next: Long)
}

internal class MobileEnvelopeCounterAllocator(
    private val store: MobileEnvelopeCounterStore,
) {
    @Synchronized
    fun reserve(): Long {
        val next = store.readNext() ?: 1L
        if (next <= 0L) throw MobileEnvelopeException()
        store.persistNext(MobileEnvelopeCounter.nextAfter(next))
        return next
    }
}

internal object MobileEnvelopeNative {
    init { System.loadLibrary("openpay_activation") }

    external fun seal(sendKey: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray?
}

/**
 * Native-only outbound envelope vault. It obtains pairing material locally,
 * persists next counter before sealing, and returns routing-safe ciphertext.
 */
internal class MobileEnvelopeVault(
    private val context: Context,
    private val accessLease: SensitiveOperationLease = object : SensitiveOperationLease {
        override fun <T> use(action: () -> T): T = action()
    },
) {
    private val counterStore = AndroidMobileEnvelopeCounterStore(context)
    private val counterAllocator = MobileEnvelopeCounterAllocator(counterStore)

    @Synchronized
    fun seal(operation: String, payload: ByteArray): Map<String, Any> {
        var plaintext = ByteArray(0)
        var outbound: PairingOutboundMaterial? = null
        var nonce = ByteArray(0)
        var aad = ByteArray(0)
        var ciphertext = ByteArray(0)
        try {
            return accessLease.use {
                plaintext = MobileEnvelopeFormat.plaintext(operation, payload)
                val material = PairingDirectionalKeyVault(context).readOutboundMaterial()
                outbound = material
                val installation = material.installationId
                val installationId = try { UUID.fromString(installation) } catch (_: Exception) { throw MobileEnvelopeException() }
                val counter = counterAllocator.reserve()
                nonce = ByteArray(MOBILE_ENVELOPE_NONCE_BYTES).also(SecureRandom()::nextBytes)
                aad = MobileEnvelopeFormat.requestAad(installationId, counter)
                ciphertext = MobileEnvelopeNative.seal(material.sendKey, nonce, plaintext, aad)
                    ?: throw MobileEnvelopeException()
                if (ciphertext.size !in MOBILE_ENVELOPE_TAG_BYTES..(MobileEnvelopeFormat.MAX_PAYLOAD_BYTES + MOBILE_ENVELOPE_TAG_BYTES + 128)) throw MobileEnvelopeException()
                mapOf(
                    "version" to 1,
                    "installation_id" to installation,
                    "counter" to MobileEnvelopeFormat.counterString(counter),
                    "nonce" to Base64.encodeToString(nonce, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP),
                    "ciphertext" to Base64.encodeToString(ciphertext, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP),
                )
            }
        } catch (_: MobileEnvelopeException) {
            throw MobileEnvelopeException()
        } catch (_: Exception) {
            throw MobileEnvelopeException()
        } finally {
            payload.fill(0)
            plaintext.fill(0)
            outbound?.dispose()
            nonce.fill(0)
            aad.fill(0)
            ciphertext.fill(0)
        }
    }

}

private class AndroidMobileEnvelopeCounterStore(context: Context) : MobileEnvelopeCounterStore {
    private val counterFile = AtomicFile(File(context.noBackupFilesDir, COUNTER_FILE))

    override fun readNext(): Long? {
        if (!counterFile.baseFile.exists() && !File(counterFile.baseFile.path + ".bak").exists()) return null
        val payload = try { counterFile.openRead().use { it.readBytes() } } catch (_: Exception) { throw MobileEnvelopeException() }
        var nonce = ByteArray(0)
        var ciphertext = ByteArray(0)
        var plaintext = ByteArray(0)
        try {
            if (payload.size != 1 + GCM_NONCE_BYTES + 8 + GCM_TAG_BYTES || payload[0].toInt() != 1) throw MobileEnvelopeException()
            nonce = payload.copyOfRange(1, 1 + GCM_NONCE_BYTES)
            ciphertext = payload.copyOfRange(1 + GCM_NONCE_BYTES, payload.size)
            plaintext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, counterKey(read = true), GCMParameterSpec(128, nonce))
                updateAAD(COUNTER_AAD)
                doFinal(ciphertext)
            }
            if (plaintext.size != 8) throw MobileEnvelopeException()
            return ByteBuffer.wrap(plaintext).long
        } catch (_: MobileEnvelopeException) {
            throw MobileEnvelopeException()
        } catch (_: Exception) {
            throw MobileEnvelopeException()
        } finally {
            payload.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
            plaintext.fill(0)
        }
    }

    override fun persistNext(next: Long) {
        val plaintext = ByteBuffer.allocate(8).putLong(next).array()
        val nonce = ByteArray(GCM_NONCE_BYTES).also(SecureRandom()::nextBytes)
        var ciphertext = ByteArray(0)
        var output: java.io.FileOutputStream? = null
        try {
            ciphertext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, counterKey(read = false), GCMParameterSpec(128, nonce))
                updateAAD(COUNTER_AAD)
                doFinal(plaintext)
            }
            output = counterFile.startWrite()
            output.write(byteArrayOf(1))
            output.write(nonce)
            output.write(ciphertext)
            output.fd.sync()
            counterFile.finishWrite(output)
            output = null
        } catch (_: Exception) {
            if (output != null) counterFile.failWrite(output)
            throw MobileEnvelopeException()
        } finally {
            plaintext.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
        }
    }

    private fun counterKey(read: Boolean): SecretKey {
        val store = try { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } } catch (_: Exception) { throw MobileEnvelopeException() }
        val existing = try { store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry } catch (_: Exception) { throw MobileEnvelopeException() }
        if (existing != null) return existing.secretKey
        if (read || counterFile.baseFile.exists() || File(counterFile.baseFile.path + ".bak").exists()) throw MobileEnvelopeException()
        return try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .setKeySize(256)
                    .build())
            }.generateKey()
        } catch (_: Exception) { throw MobileEnvelopeException() }
    }

    private companion object {
        const val COUNTER_FILE = "mobile_envelope_counter_v1"
        const val KEY_ALIAS = "openpaycongo.mobile-envelope.counter.v1"
        const val GCM_NONCE_BYTES = 12
        const val GCM_TAG_BYTES = 16
        val COUNTER_AAD = "openpaycongo/mobile-envelope/counter/v1".toByteArray(StandardCharsets.US_ASCII)
    }
}
