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
 * key, then atomically replaced in no-backup storage. No read API exists.
 */
internal class PairingDirectionalKeyVault(context: Context) {
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
