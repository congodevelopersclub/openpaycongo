package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

/**
 * Crash-safe, native-only post-confirmation pairing exchange. It intentionally
 * excludes pre-completion request retry material: only a server-authenticated
 * SAS may survive process death, until activation promotes active keys.
 */
internal class PairingConfirmedExchangeVault(context: Context) {
    private val atomicFile = AtomicFile(File(context.noBackupFilesDir, RECORD_FILE))

    fun save(exchange: ConfirmedPairingExchange) = synchronized(STORAGE_LOCK) {
        var plaintext = ByteArray(0)
        var nonce = ByteArray(0)
        var ciphertext = ByteArray(0)
        var payload = ByteArray(0)
        var output: java.io.FileOutputStream? = null
        try {
            plaintext = PairingConfirmedExchangeFormat.copyRecord(exchange)
            nonce = ByteArray(GCM_NONCE_BYTES).also(SecureRandom()::nextBytes)
            ciphertext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, keyForWrite(), GCMParameterSpec(GCM_TAG_BITS, nonce))
                updateAAD(AAD)
                doFinal(plaintext)
            }
            payload = ByteArray(1 + nonce.size + ciphertext.size)
            payload[0] = ENVELOPE_VERSION
            System.arraycopy(nonce, 0, payload, 1, nonce.size)
            System.arraycopy(ciphertext, 0, payload, 1 + nonce.size, ciphertext.size)
            output = atomicFile.startWrite()
            output.write(payload)
            output.fd.sync()
            atomicFile.finishWrite(output)
            output = null
        } catch (_: Exception) {
            if (output != null) atomicFile.failWrite(output)
            throw PairingActivationException()
        } finally {
            plaintext.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
            payload.fill(0)
        }
    }

    fun restore(): ConfirmedPairingExchange? = synchronized(STORAGE_LOCK) {
        if (!atomicFile.baseFile.exists() && !File(atomicFile.baseFile.path + ".bak").exists()) return null
        var payload = ByteArray(0)
        var nonce = ByteArray(0)
        var ciphertext = ByteArray(0)
        var plaintext = ByteArray(0)
        try {
            payload = atomicFile.openRead().use { it.readBytes() }
            if (payload.size <= 1 + GCM_NONCE_BYTES || payload[0] != ENVELOPE_VERSION) throw PairingActivationException()
            nonce = payload.copyOfRange(1, 1 + GCM_NONCE_BYTES)
            ciphertext = payload.copyOfRange(1 + GCM_NONCE_BYTES, payload.size)
            plaintext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, keyForExisting(), GCMParameterSpec(GCM_TAG_BITS, nonce))
                updateAAD(AAD)
                doFinal(ciphertext)
            }
            return PairingConfirmedExchangeFormat.readRecord(plaintext)
        } catch (_: Exception) {
            try {
                atomicFile.delete()
            } catch (_: Exception) {
                // The unauthenticable record is never returned. A later start
                // must fail closed rather than treat it as restored state.
            }
            throw PairingActivationException()
        } finally {
            payload.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
            plaintext.fill(0)
        }
    }

    fun clear() = synchronized(STORAGE_LOCK) {
        atomicFile.delete()
        if (!PairingConfirmedExchangeFiles.isAbsent(atomicFile.baseFile)) {
            throw PairingActivationException()
        }
    }

    private fun keyForWrite(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }
    }

    private fun keyForExisting(): SecretKey {
        val store = try { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } } catch (_: Exception) { throw PairingActivationException() }
        return (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey ?: throw PairingActivationException()
    }

    private companion object {
        const val RECORD_FILE = "pairing_confirmed_exchange_v1"
        const val KEY_ALIAS = "openpaycongo.pairing.confirmed-exchange.v1"
        const val ENVELOPE_VERSION: Byte = 1
        const val GCM_NONCE_BYTES = 12
        const val GCM_TAG_BITS = 128
        val AAD = "openpaycongo/pairing/confirmed-exchange/v1".toByteArray(StandardCharsets.US_ASCII)
        val STORAGE_LOCK = Any()
    }
}

internal object PairingConfirmedExchangeFiles {
    fun isAbsent(baseFile: File): Boolean =
        !baseFile.exists() && !File(baseFile.path + ".bak").exists()
}

internal data class ConfirmedPairingExchange(
    val intent: ByteArray,
    val canonicalServerBaseUrl: String,
    val sendKey: ByteArray,
    val receiveKey: ByteArray,
    val sas: String,
) {
    fun dispose() {
        intent.fill(0)
        sendKey.fill(0)
        receiveKey.fill(0)
    }
}

internal object PairingConfirmedExchangeFormat {
    private const val RECORD_VERSION: Byte = 1
    private const val INTENT_BYTES = 16
    private const val KEY_BYTES = 32
    private const val SAS_BYTES = 6

    fun copyRecord(exchange: ConfirmedPairingExchange): ByteArray {
        val origin = PairingServerAuthority.canonicalize(exchange.canonicalServerBaseUrl).toByteArray(StandardCharsets.UTF_8)
        try {
            if (exchange.intent.size != INTENT_BYTES || exchange.sendKey.size != KEY_BYTES ||
                exchange.receiveKey.size != KEY_BYTES || !Regex("^[0-9]{6}$").matches(exchange.sas) || origin.size !in 1..512
            ) throw PairingActivationException()
            return ByteBuffer.allocate(1 + INTENT_BYTES + 2 + origin.size + KEY_BYTES + KEY_BYTES + SAS_BYTES)
                .put(RECORD_VERSION)
                .put(exchange.intent)
                .putShort(origin.size.toShort())
                .put(origin)
                .put(exchange.sendKey)
                .put(exchange.receiveKey)
                .put(exchange.sas.toByteArray(StandardCharsets.US_ASCII))
                .array()
        } finally {
            origin.fill(0)
        }
    }

    fun readRecord(record: ByteArray): ConfirmedPairingExchange {
        if (record.size < 1 + INTENT_BYTES + 2 + KEY_BYTES + KEY_BYTES + SAS_BYTES || record[0] != RECORD_VERSION) {
            throw PairingActivationException()
        }
        val buffer = ByteBuffer.wrap(record)
        buffer.position(1 + INTENT_BYTES)
        val originSize = buffer.short.toInt() and 0xffff
        if (originSize !in 1..512 || record.size != 1 + INTENT_BYTES + 2 + originSize + KEY_BYTES + KEY_BYTES + SAS_BYTES) {
            throw PairingActivationException()
        }
        val intent = record.copyOfRange(1, 1 + INTENT_BYTES)
        val originStart = 1 + INTENT_BYTES + 2
        val sendStart = originStart + originSize
        val receiveStart = sendStart + KEY_BYTES
        val sasStart = receiveStart + KEY_BYTES
        var origin = ByteArray(0)
        try {
            origin = record.copyOfRange(originStart, sendStart)
            val canonicalOrigin = PairingServerAuthority.canonicalize(String(origin, StandardCharsets.UTF_8))
            val sas = String(record, sasStart, SAS_BYTES, StandardCharsets.US_ASCII)
            if (!Regex("^[0-9]{6}$").matches(sas)) throw PairingActivationException()
            return ConfirmedPairingExchange(
                intent = intent,
                canonicalServerBaseUrl = canonicalOrigin,
                sendKey = record.copyOfRange(sendStart, receiveStart),
                receiveKey = record.copyOfRange(receiveStart, sasStart),
                sas = sas,
            )
        } catch (_: Exception) {
            intent.fill(0)
            throw PairingActivationException()
        } finally {
            origin.fill(0)
        }
    }
}
