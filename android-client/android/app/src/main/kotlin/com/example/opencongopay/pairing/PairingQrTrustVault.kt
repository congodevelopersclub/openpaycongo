package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class PairingQrTrustStorageException : Exception()

/** Exact, portable QR fingerprint representation. */
internal object PairingQrTrustFormat {
    const val FINGERPRINT_BYTES = 32
    private const val FINGERPRINT_LENGTH = 43

    fun canonicalFingerprint(value: String): String {
        if (value.length != FINGERPRINT_LENGTH || !value.all { it.isAsciiFingerprintCharacter() }) {
            throw PairingQrTrustStorageException()
        }
        val decoded = try {
            Base64.getUrlDecoder().decode(value)
        } catch (_: IllegalArgumentException) {
            throw PairingQrTrustStorageException()
        }
        try {
            if (decoded.size != FINGERPRINT_BYTES || Base64.getUrlEncoder().withoutPadding().encodeToString(decoded) != value) {
                throw PairingQrTrustStorageException()
            }
            return value
        } finally {
            decoded.fill(0)
        }
    }

    private fun Char.isAsciiFingerprintCharacter(): Boolean =
        this in 'A'..'Z' || this in 'a'..'z' || this in '0'..'9' || this == '_' || this == '-'
}

/**
 * Single ADR-004 enrollment-signing pin, encrypted at rest with a
 * non-exportable Android Keystore AES key. It deliberately has no clear or
 * replace operation: key loss/replacement requires later authenticated
 * first-use/SAS recovery, never silent continuity fallback.
 */
internal class PairingQrTrustVault(context: Context) {
    private val recordFile = File(context.noBackupFilesDir, RECORD_FILE)
    private val atomicFile = AtomicFile(recordFile)

    @Synchronized
    fun lookup(candidate: String): String {
        val fingerprint = PairingQrTrustFormat.canonicalFingerprint(candidate)
        val existing = readFingerprintOrNull()
        if (existing == null) {
            keyForEmptyStore()
            return "none"
        }
        return if (existing == fingerprint) "matching" else "conflict"
    }

    @Synchronized
    fun persistVerifiedFingerprint(candidate: String): String {
        val fingerprint = PairingQrTrustFormat.canonicalFingerprint(candidate)
        val existing = readFingerprintOrNull()
        if (existing != null) return if (existing == fingerprint) "already_stored" else "conflict"
        writeFingerprint(fingerprint)
        return "stored"
    }

    private fun readFingerprintOrNull(): String? {
        if (!recordFile.exists()) return null
        val encrypted = try {
            atomicFile.openRead().use { input -> input.readBytes() }
        } catch (_: Exception) {
            throw PairingQrTrustStorageException()
        }
        if (encrypted.size <= GCM_NONCE_BYTES) throw PairingQrTrustStorageException()
        val nonce = encrypted.copyOfRange(0, GCM_NONCE_BYTES)
        val ciphertext = encrypted.copyOfRange(GCM_NONCE_BYTES, encrypted.size)
        val plaintext = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, existingKey(), GCMParameterSpec(GCM_TAG_BITS, nonce))
                updateAAD(AAD)
                doFinal(ciphertext)
            }
        } catch (_: Exception) {
            throw PairingQrTrustStorageException()
        } finally {
            nonce.fill(0)
            ciphertext.fill(0)
            encrypted.fill(0)
        }
        try {
            return PairingQrTrustFormat.canonicalFingerprint(String(plaintext, StandardCharsets.US_ASCII))
        } finally {
            plaintext.fill(0)
        }
    }

    private fun writeFingerprint(fingerprint: String) {
        val nonce = ByteArray(GCM_NONCE_BYTES).also(SecureRandom()::nextBytes)
        val plaintext = fingerprint.toByteArray(StandardCharsets.US_ASCII)
        var output: java.io.FileOutputStream? = null
        try {
            val ciphertext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, keyForEmptyStore(), GCMParameterSpec(GCM_TAG_BITS, nonce))
                updateAAD(AAD)
                doFinal(plaintext)
            }
            val payload = ByteArray(nonce.size + ciphertext.size)
            System.arraycopy(nonce, 0, payload, 0, nonce.size)
            System.arraycopy(ciphertext, 0, payload, nonce.size, ciphertext.size)
            ciphertext.fill(0)
            output = atomicFile.startWrite()
            output.write(payload)
            output.fd.sync()
            atomicFile.finishWrite(output)
            output = null
            payload.fill(0)
        } catch (_: Exception) {
            if (output != null) atomicFile.failWrite(output)
            throw PairingQrTrustStorageException()
        } finally {
            nonce.fill(0)
            plaintext.fill(0)
        }
    }

    private fun existingKey(): SecretKey = try {
        val entry = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            .getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
            ?: throw PairingQrTrustStorageException()
        entry.secretKey
    } catch (_: PairingQrTrustStorageException) {
        throw PairingQrTrustStorageException()
    } catch (_: Exception) {
        throw PairingQrTrustStorageException()
    }

    private fun keyForEmptyStore(): SecretKey {
        val store = try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        } catch (_: Exception) {
            throw PairingQrTrustStorageException()
        }
        val entry = store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (entry != null) return entry.secretKey
        return try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(
                    KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build(),
                )
            }.generateKey()
        } catch (_: Exception) {
            throw PairingQrTrustStorageException()
        }
    }

    private companion object {
        const val RECORD_FILE = "pairing_qr_trust_v1"
        const val KEY_ALIAS = "openpaycongo.pairing_qr_trust.v1"
        const val GCM_NONCE_BYTES = 12
        const val GCM_TAG_BITS = 128
        val AAD = "openpaycongo/pairing/enrollment-signing-pin/v1".toByteArray(StandardCharsets.US_ASCII)
    }
}
