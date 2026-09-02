package com.congodeveloperclub.opencongopay.pairing

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.UUID

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

internal object PairingActivationNative {
    init { System.loadLibrary("openpay_activation") }

    external fun decrypt(receiveKey: ByteArray, nonce: ByteArray, ciphertext: ByteArray, aad: ByteArray): ByteArray?
}
