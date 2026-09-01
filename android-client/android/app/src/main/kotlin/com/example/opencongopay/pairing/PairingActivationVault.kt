package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONObject
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

internal class PairingActivationException : Exception()

internal object PairingActivationEnvelope {
    private const val NONCE_BYTES = 24
    private const val INTENT_BYTES = 16
    private const val DOMAIN = "openpaycongo/pairing/activation-response/v2"

    fun aad(intent: ByteArray): ByteArray {
        if (intent.size != INTENT_BYTES) throw PairingActivationException()
        val domain = DOMAIN.toByteArray(StandardCharsets.UTF_8)
        if (domain.size != 43) throw PairingActivationException()
        return ByteBuffer.allocate(2 + domain.size + 2 + intent.size)
            .putShort(domain.size.toShort())
            .put(domain)
            .putShort(intent.size.toShort())
            .put(intent)
            .array()
    }

    fun validate(intent: ByteArray, nonce: ByteArray, ciphertext: ByteArray) {
        if (intent.size != INTENT_BYTES || nonce.size != NONCE_BYTES || ciphertext.size !in 17..8192) {
            throw PairingActivationException()
        }
    }
}

internal data class PairingActivationCredential(
    val installationId: String,
    val bearerToken: String,
) {
    companion object {
        fun parse(plaintext: ByteArray): PairingActivationCredential = try {
            val objectValue = JSONObject(String(plaintext, StandardCharsets.UTF_8))
            if (objectValue.length() != 3 || objectValue.optInt("version", -1) != 2) {
                throw PairingActivationException()
            }
            val installationId = objectValue.optString("installation_id", "")
            val bearerToken = objectValue.optString("bearer_token", "")
            UUID.fromString(installationId)
            if (!UUID_PATTERN.matches(installationId) ||
                bearerToken.length !in 1..8192 ||
                bearerToken.any { it.code <= 0x20 || it.code == 0x7f }
            ) throw PairingActivationException()
            PairingActivationCredential(installationId, bearerToken)
        } catch (_: Exception) {
            throw PairingActivationException()
        }

        private val UUID_PATTERN = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    }
}

/** Keystore-only write sink. There is deliberately no credential read API. */
internal class PairingActivationCredentialVault(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "pairing_activation_credential_v2"))

    fun save(credential: PairingActivationCredential) {
        val plaintext = JSONObject()
            .put("version", 2)
            .put("installation_id", credential.installationId)
            .put("bearer_token", credential.bearerToken)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
        var ciphertext = ByteArray(0)
        var payload = ByteArray(0)
        var output: java.io.FileOutputStream? = null
        try {
            ciphertext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(128, nonce))
                updateAAD(AAD)
                doFinal(plaintext)
            }
            payload = ByteArray(1 + nonce.size + ciphertext.size)
            payload[0] = 1
            System.arraycopy(nonce, 0, payload, 1, nonce.size)
            System.arraycopy(ciphertext, 0, payload, 1 + nonce.size, ciphertext.size)
            output = file.startWrite()
            output.write(payload)
            output.fd.sync()
            file.finishWrite(output)
            output = null
        } catch (_: Exception) {
            if (output != null) file.failWrite(output)
            throw PairingActivationException()
        } finally {
            plaintext.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
            payload.fill(0)
        }
    }

    private fun key(): SecretKey {
        val store = try { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } } catch (_: Exception) { throw PairingActivationException() }
        val existing = try { store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry } catch (_: Exception) { throw PairingActivationException() }
        if (existing != null) return existing.secretKey
        if (File(file.baseFile.path).exists() || File(file.baseFile.path + ".bak").exists()) throw PairingActivationException()
        return try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .setKeySize(256)
                    .build())
            }.generateKey()
        } catch (_: Exception) { throw PairingActivationException() }
    }

    private companion object {
        const val ALIAS = "openpaycongo.pairing.activation-credential.v2"
        val AAD = "openpaycongo/pairing/activation-credential/v2".toByteArray(StandardCharsets.US_ASCII)
    }
}

internal object PairingActivationNative {
    init { System.loadLibrary("openpay_activation") }

    external fun decrypt(receiveKey: ByteArray, nonce: ByteArray, ciphertext: ByteArray, aad: ByteArray): ByteArray?
}
