package com.congodeveloperclub.opencongopay.sms

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal interface SecretKeyAccess {
    fun keyForEncrypt(): SecretKey
    fun keyForDecrypt(): SecretKey
}

internal class KeyInvalidatedException(cause: Throwable? = null) : Exception(cause)

internal interface EnvelopeCrypto {
    fun encrypt(type: String, identity: String, cleartext: ByteArray): ByteArray
    fun decrypt(type: String, identity: String, payload: ByteArray): ByteArray
}

internal class AesGcmEnvelopeCrypto(
    private val keys: SecretKeyAccess,
    private val keyDomain: String,
    private val random: SecureRandom = SecureRandom(),
) : EnvelopeCrypto {
    companion object {
        private const val VERSION: Byte = 3
        private const val NONCE_BYTES = 12
    }

    override fun encrypt(type: String, identity: String, cleartext: ByteArray): ByteArray {
        val nonce = ByteArray(NONCE_BYTES).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keys.keyForEncrypt(), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad(type, identity))
        val ciphertext = cipher.doFinal(cleartext)
        return ByteBuffer.allocate(2 + nonce.size + ciphertext.size)
            .put(VERSION)
            .put(nonce.size.toByte())
            .put(nonce)
            .put(ciphertext)
            .array()
    }

    override fun decrypt(type: String, identity: String, payload: ByteArray): ByteArray {
        val input = ByteBuffer.wrap(payload)
        if (input.remaining() < 2 || input.get() != VERSION) {
            throw IllegalArgumentException("invalid_ciphertext_version")
        }
        val nonceLength = input.get().toInt() and 0xff
        if (nonceLength != NONCE_BYTES || input.remaining() < nonceLength + 16) {
            throw IllegalArgumentException("invalid_ciphertext_length")
        }
        val nonce = ByteArray(nonceLength).also(input::get)
        val ciphertext = ByteArray(input.remaining()).also(input::get)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keys.keyForDecrypt(), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad(type, identity))
        return cipher.doFinal(ciphertext)
    }

    private fun aad(type: String, identity: String): ByteArray {
        require(type.matches(Regex("^[a-z][a-z-]{2,31}$")))
        require(identity.length in 1..128)
        return "openpay-sms|v3|$keyDomain|$type|${identity.length}:$identity"
            .toByteArray(StandardCharsets.UTF_8)
    }
}
