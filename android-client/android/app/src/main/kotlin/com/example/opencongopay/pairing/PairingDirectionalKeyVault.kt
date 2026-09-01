package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class PairingDirectionalKeyStorageException : Exception()

/** Fixed-format plaintext before Android Keystore AEAD encryption. */
internal object PairingDirectionalKeyFormat {
    const val KEY_BYTES = 32
    private const val RECORD_VERSION: Byte = 1

    fun copyRecord(sendKey: ByteArray, receiveKey: ByteArray): ByteArray {
        if (sendKey.size != KEY_BYTES || receiveKey.size != KEY_BYTES) {
            throw PairingDirectionalKeyStorageException()
        }
        return ByteArray(1 + (KEY_BYTES * 2)).also { record ->
            record[0] = RECORD_VERSION
            System.arraycopy(sendKey, 0, record, 1, KEY_BYTES)
            System.arraycopy(receiveKey, 0, record, 1 + KEY_BYTES, KEY_BYTES)
        }
    }
}

/**
 * Stores only current pairing directional keys. Keys are copied into one
 * versioned record, AEAD-encrypted with a non-exportable Android Keystore AES
 * key, then atomically replaced in no-backup storage. No Flutter/Dart key-read
 * API exists; native pairing and envelope code can use narrowly scoped reads.
 */
internal class PairingDirectionalKeyVault(private val context: Context) {
    private val recordFile = File(context.noBackupFilesDir, RECORD_FILE)
    private val atomicFile = AtomicFile(recordFile)

    @Synchronized
    fun save(sendKey: ByteArray, receiveKey: ByteArray) {
        val plaintext = PairingDirectionalKeyFormat.copyRecord(sendKey, receiveKey)
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

    /**
     * Native-only activation path. Directional keys never leave this vault:
     * receive key enters JNI only for authenticated XChaCha decryption, then
     * all temporary buffers are wiped before returning a redacted outcome.
     */
    @Synchronized
    fun consumeActivation(intent: ByteArray, nonce: ByteArray, ciphertext: ByteArray) {
        PairingActivationEnvelope.validate(intent, nonce, ciphertext)
        val record = decryptRecord()
        val receiveKey = ByteArray(PairingDirectionalKeyFormat.KEY_BYTES)
        var aad = ByteArray(0)
        var plaintext = ByteArray(0)
        try {
            if (record.size != 1 + (PairingDirectionalKeyFormat.KEY_BYTES * 2) || record[0].toInt() != 1) {
                throw PairingActivationException()
            }
            System.arraycopy(record, 1 + PairingDirectionalKeyFormat.KEY_BYTES, receiveKey, 0, receiveKey.size)
            aad = PairingActivationEnvelope.aad(intent)
            plaintext = PairingActivationNative.decrypt(receiveKey, nonce, ciphertext, aad)
                ?: throw PairingActivationException()
            PairingActivationCredentialVault(context).save(PairingActivationCredential.parse(plaintext))
        } catch (_: PairingActivationException) {
            throw PairingActivationException()
        } catch (_: Exception) {
            throw PairingActivationException()
        } finally {
            record.fill(0)
            receiveKey.fill(0)
            aad.fill(0)
            plaintext.fill(0)
        }
    }

    /** Native-only access for outbound request sealing. Never exposed to Flutter. */
    @Synchronized
    fun readSendKey(): ByteArray {
        val record = decryptRecord()
        try {
            if (record.size != 1 + (PairingDirectionalKeyFormat.KEY_BYTES * 2) || record[0].toInt() != 1) {
                throw PairingActivationException()
            }
            return record.copyOfRange(1, 1 + PairingDirectionalKeyFormat.KEY_BYTES)
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
