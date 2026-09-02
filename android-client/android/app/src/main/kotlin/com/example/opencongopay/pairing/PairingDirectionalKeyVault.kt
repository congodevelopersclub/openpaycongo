package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class PairingDirectionalKeyStorageException : Exception()

/**
 * The installation identity and directional keys are one outbound-envelope
 * generation. They must never be persisted independently: a reader sees the
 * complete old generation or the complete promoted generation.
 */
internal object PairingDirectionalKeyFormat {
    const val KEY_BYTES = 32
    const val INSTALLATION_ID_BYTES = 16
    private const val RECORD_VERSION: Byte = 2

    fun copyRecord(installationId: String, sendKey: ByteArray, receiveKey: ByteArray): ByteArray {
        if (sendKey.size != KEY_BYTES || receiveKey.size != KEY_BYTES) {
            throw PairingDirectionalKeyStorageException()
        }
        val installation = try {
            UUID.fromString(installationId)
        } catch (_: Exception) {
            throw PairingDirectionalKeyStorageException()
        }
        return ByteArray(1 + INSTALLATION_ID_BYTES + (KEY_BYTES * 2)).also { record ->
            record[0] = RECORD_VERSION
            ByteBuffer.wrap(record, 1, INSTALLATION_ID_BYTES)
                .putLong(installation.mostSignificantBits)
                .putLong(installation.leastSignificantBits)
            System.arraycopy(sendKey, 0, record, 1 + INSTALLATION_ID_BYTES, KEY_BYTES)
            System.arraycopy(receiveKey, 0, record, 1 + INSTALLATION_ID_BYTES + KEY_BYTES, KEY_BYTES)
        }
    }

    fun outboundMaterial(record: ByteArray): PairingOutboundMaterial {
        if (record.size != 1 + INSTALLATION_ID_BYTES + (KEY_BYTES * 2) || record[0] != RECORD_VERSION) {
            throw PairingActivationException()
        }
        val installation = ByteBuffer.wrap(record, 1, INSTALLATION_ID_BYTES).run {
            UUID(long, long).toString()
        }
        val sendKeyStart = 1 + INSTALLATION_ID_BYTES
        return PairingOutboundMaterial(
            installationId = installation,
            sendKey = record.copyOfRange(sendKeyStart, sendKeyStart + KEY_BYTES),
        )
    }
}

internal class PairingOutboundMaterial(
    val installationId: String,
    val sendKey: ByteArray,
) {
    fun dispose() = sendKey.fill(0)
}

/**
 * Stores the current outbound-envelope generation. Installation identity and
 * directional keys are copied into one versioned record, AEAD-encrypted with a
 * non-exportable Android Keystore AES key, then atomically replaced in
 * no-backup storage. No Flutter/Dart key-read API exists.
 */
internal class PairingDirectionalKeyVault(private val context: Context) {
    private val recordFile = File(context.noBackupFilesDir, RECORD_FILE)
    private val atomicFile = AtomicFile(recordFile)

    @Synchronized
    fun save(installationId: String, sendKey: ByteArray, receiveKey: ByteArray) {
        val plaintext = PairingDirectionalKeyFormat.copyRecord(installationId, sendKey, receiveKey)
        val nonce = ByteArray(GCM_NONCE_BYTES).also(SecureRandom()::nextBytes)
        var ciphertext = ByteArray(0)
        var payload = ByteArray(0)
        var output: java.io.FileOutputStream? = null
        try {
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
            throw PairingDirectionalKeyStorageException()
        } finally {
            plaintext.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
            payload.fill(0)
        }
    }

    /** Native-only outbound-envelope read. Never exposed to Flutter. */
    @Synchronized
    fun readOutboundMaterial(): PairingOutboundMaterial {
        val record = decryptRecord()
        try {
            return PairingDirectionalKeyFormat.outboundMaterial(record)
        } finally {
            record.fill(0)
        }
    }

    private fun decryptRecord(): ByteArray {
        val payload = try { atomicFile.openRead().use { it.readBytes() } } catch (_: Exception) { throw PairingActivationException() }
        var nonce = ByteArray(0)
        var ciphertext = ByteArray(0)
        try {
            if (payload.size <= 13 || payload[0] != ENVELOPE_VERSION) throw PairingActivationException()
            nonce = payload.copyOfRange(1, 1 + GCM_NONCE_BYTES)
            ciphertext = payload.copyOfRange(1 + GCM_NONCE_BYTES, payload.size)
            return Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, keyForRead(), GCMParameterSpec(GCM_TAG_BITS, nonce))
                updateAAD(AAD)
                doFinal(ciphertext)
            }
        } catch (_: PairingActivationException) {
            throw PairingActivationException()
        } catch (_: Exception) {
            throw PairingActivationException()
        } finally {
            payload.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
        }
    }

    private fun keyForWrite(): SecretKey {
        val store = try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        } catch (_: Exception) {
            throw PairingDirectionalKeyStorageException()
        }
        val existing = try {
            store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        } catch (_: Exception) {
            throw PairingDirectionalKeyStorageException()
        }
        if (existing != null) return existing.secretKey
        if (recordFile.exists() || File(recordFile.path + ".bak").exists()) {
            throw PairingDirectionalKeyStorageException()
        }
        return try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(
                    KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setRandomizedEncryptionRequired(true)
                        .setKeySize(256)
                        .build(),
                )
            }.generateKey()
        } catch (_: Exception) {
            throw PairingDirectionalKeyStorageException()
        }
    }

    private fun keyForRead(): SecretKey {
        val store = try { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } } catch (_: Exception) { throw PairingActivationException() }
        return try {
            (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
                ?: throw PairingActivationException()
        } catch (_: PairingActivationException) {
            throw PairingActivationException()
        } catch (_: Exception) {
            throw PairingActivationException()
        }
    }

    private companion object {
        const val RECORD_FILE = "pairing_directional_keys_v1"
        const val KEY_ALIAS = "openpaycongo.pairing.directional-keys.v1"
        const val ENVELOPE_VERSION: Byte = 1
        const val GCM_NONCE_BYTES = 12
        const val GCM_TAG_BITS = 128
        val AAD = "openpaycongo/pairing/directional-keys/v1"
            .toByteArray(StandardCharsets.US_ASCII)
    }
}
