package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
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

/**
 * Read-only support for releases that persisted the credential separately from
 * the directional keys. The first native envelope read atomically migrates the
 * two authenticated legacy records into the active-generation vault.
 */
internal class LegacyPairingActivationCredentialVault(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, RECORD_FILE))

    fun hasRecord(): Boolean = file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()

    fun read(): PairingActivationCredential {
        val payload = try {
            file.openRead().use { it.readBytes() }
        } catch (_: Exception) {
            throw PairingActivationException()
        }
        var nonce = ByteArray(0)
        var ciphertext = ByteArray(0)
        var plaintext = ByteArray(0)
        try {
            if (payload.size <= 13 || payload[0].toInt() != ENVELOPE_VERSION) {
                throw PairingActivationException()
            }
            nonce = payload.copyOfRange(1, 13)
            ciphertext = payload.copyOfRange(13, payload.size)
            plaintext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, existingKey(), GCMParameterSpec(GCM_TAG_BITS, nonce))
                updateAAD(AAD)
                doFinal(ciphertext)
            }
            return PairingActivationCredential.parse(plaintext)
        } catch (_: PairingActivationException) {
            throw PairingActivationException()
        } catch (_: Exception) {
            throw PairingActivationException()
        } finally {
            payload.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
            plaintext.fill(0)
        }
    }

    fun delete() = file.delete()

    private fun existingKey(): SecretKey {
        val store = try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        } catch (_: Exception) {
            throw PairingActivationException()
        }
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
        const val RECORD_FILE = "pairing_activation_credential_v2"
        const val KEY_ALIAS = "openpaycongo.pairing.activation-credential.v2"
        const val ENVELOPE_VERSION: Byte = 1
        const val GCM_TAG_BITS = 128
        val AAD = "openpaycongo/pairing/activation-credential/v2"
            .toByteArray(StandardCharsets.US_ASCII)
    }
}

internal object PairingActivationNative {
    init { System.loadLibrary("openpay_activation") }

    external fun decrypt(receiveKey: ByteArray, nonce: ByteArray, ciphertext: ByteArray, aad: ByteArray): ByteArray?
}
