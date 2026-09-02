package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/**
 * One in-memory pairing exchange. Directional keys are never returned through
 * Flutter: they survive only until server-confirmed activation atomically
 * promotes their complete active pairing generation in Android Keystore storage.
 */
internal class PairingV2NativeCompletion(private val context: Context) {
    private var pending: PendingExchange? = null
    private val recoveryVault by lazy { PairingConfirmedExchangeVault(context) }

    @Synchronized
    fun begin(
        intentId: String,
        serverPublicKey: String,
        canonicalServerBaseUrl: String,
        pairingSecret: ByteArray,
    ): Map<String, String> {
        var intent = ByteArray(0)
        var serverKey = ByteArray(0)
        var nativeMaterial: Array<ByteArray>? = null
        var replacement: PendingExchange? = null
        try {
            if (pairingSecret.size != PairingDirectionalKeyFormat.KEY_BYTES) throw PairingActivationException()
            intent = decodeExact(intentId, INTENT_BYTES)
            serverKey = decodeExact(serverPublicKey, PairingDirectionalKeyFormat.KEY_BYTES)
            val serverBaseUrl = PairingServerAuthority.canonicalize(canonicalServerBaseUrl)
            nativeMaterial = PairingV2Native.begin(intent, serverKey, pairingSecret)
                ?: throw PairingActivationException()
            val material = nativeMaterial
            if (material.size != 5 ||
                material[0].size != PairingDirectionalKeyFormat.KEY_BYTES ||
                material[1].size != NONCE_BYTES ||
                material[2].size != PairingDirectionalKeyFormat.KEY_BYTES + TAG_BYTES ||
                material[3].size != PairingDirectionalKeyFormat.KEY_BYTES ||
                material[4].size != PairingDirectionalKeyFormat.KEY_BYTES
            ) throw PairingActivationException()
            replacement = PendingExchange(
                intent = intent.copyOf(),
                canonicalServerBaseUrl = serverBaseUrl,
                sendKey = material[3].copyOf(),
                receiveKey = material[4].copyOf(),
            )
            val response = mapOf(
                "intent_id" to intentId,
                "client_public_key" to encode(material[0]),
                "nonce" to encode(material[1]),
                "ciphertext" to encode(material[2]),
            )
            val previous = pending
            recoveryVault.clear()
            pending = replacement
            replacement = null
            previous?.dispose()
            return response
        } catch (_: PairingActivationException) {
            throw PairingActivationException()
        } catch (_: Exception) {
            throw PairingActivationException()
        } finally {
            pairingSecret.fill(0)
            intent.fill(0)
            serverKey.fill(0)
            nativeMaterial?.forEach { it.fill(0) }
            replacement?.dispose()
        }
    }

    @Synchronized
    fun accept(intentId: String, nonceValue: String, ciphertextValue: String): String {
        val current = pending ?: throw PairingActivationException()
        var intent = ByteArray(0)
        var nonce = ByteArray(0)
        var ciphertext = ByteArray(0)
        var aad = ByteArray(0)
        var plaintext = ByteArray(0)
        var responseKey = ByteArray(0)
        var confirmedExchange: ConfirmedPairingExchange? = null
        try {
            intent = decodeExact(intentId, INTENT_BYTES)
            nonce = decodeExact(nonceValue, NONCE_BYTES)
            ciphertext = decodeBounded(ciphertextValue, TAG_BYTES + 1, MAXIMUM_RESPONSE_CIPHERTEXT_BYTES)
            if (!MessageDigest.isEqual(current.intent, intent)) throw PairingActivationException()
            aad = PairingV2CompletionEnvelope.responseAad(intent)
            // JNI clears its input buffer. Keep the pending vault copy intact
            // until both directional keys are persisted atomically below.
            responseKey = current.receiveKey.copyOf()
            plaintext = PairingActivationNative.decrypt(responseKey, nonce, ciphertext, aad)
                ?: throw PairingActivationException()
            val sas = PairingV2CompletionResponse.readSas(plaintext)
            if (current.confirmed) throw PairingActivationException()
            current.confirmed = true
            current.sas = sas
            val exchange = ConfirmedPairingExchange(
                    intent = current.intent.copyOf(),
                    canonicalServerBaseUrl = current.canonicalServerBaseUrl,
                    sendKey = current.sendKey.copyOf(),
                    receiveKey = current.receiveKey.copyOf(),
                    sas = sas,
            )
            confirmedExchange = exchange
            recoveryVault.save(exchange)
            return sas
        } catch (_: PairingActivationException) {
            if (current.confirmed) {
                pending = null
                try {
                    recoveryVault.clear()
                } finally {
                    current.dispose()
                }
            }
            throw PairingActivationException()
        } catch (_: Exception) {
            if (current.confirmed) {
                pending = null
                try {
                    recoveryVault.clear()
                } finally {
                    current.dispose()
                }
            }
            throw PairingActivationException()
        } finally {
            intent.fill(0)
            nonce.fill(0)
            ciphertext.fill(0)
            aad.fill(0)
            plaintext.fill(0)
            responseKey.fill(0)
            confirmedExchange?.dispose()
        }
    }

    /**
     * The activation credential is authenticated with the accepted pending
     * receive key. Its credential, installation identity, and both directional
     * keys are then promoted in one encrypted AtomicFile record. Therefore a
     * credential-write failure cannot replace an existing key generation.
     */
    @Synchronized
    fun consumeActivation(
        intent: ByteArray,
        nonce: ByteArray,
        ciphertext: ByteArray,
    ) {
        val current = pending ?: throw PairingActivationException()
        var aad = ByteArray(0)
        var responseKey = ByteArray(0)
        var plaintext = ByteArray(0)
        var promoted = false
        try {
            if (!current.confirmed) throw PairingActivationException()
            PairingActivationEnvelope.validate(intent, nonce, ciphertext)
            if (!MessageDigest.isEqual(current.intent, intent)) throw PairingActivationException()
            aad = PairingActivationEnvelope.aad(intent)
            responseKey = current.receiveKey.copyOf()
            plaintext = PairingActivationNative.decrypt(responseKey, nonce, ciphertext, aad)
                ?: throw PairingActivationException()
            val credential = PairingActivationCredential.parse(plaintext)
            // The confirmed record must be gone before an active-generation
            // write. Otherwise a stale recovered exchange could later replace
            // active directional keys after a failed delete. clear() verifies
            // both AtomicFile base and backup removal.
            recoveryVault.clear()
            PairingDirectionalKeyVault(context).save(
                credential,
                current.canonicalServerBaseUrl,
                current.sendKey,
                current.receiveKey,
            )
            pending = null
            promoted = true
        } catch (_: PairingActivationException) {
            pending = null
            try {
                recoveryVault.clear()
            } finally {
                current.dispose()
            }
            throw PairingActivationException()
        } catch (_: Exception) {
            pending = null
            try {
                recoveryVault.clear()
            } finally {
                current.dispose()
            }
            throw PairingActivationException()
        } finally {
            aad.fill(0)
            responseKey.fill(0)
            plaintext.fill(0)
            if (promoted) current.dispose()
        }
    }

    @Synchronized
    fun cancel() {
        val current = pending
        pending = null
        try {
            recoveryVault.clear()
        } finally {
            current?.dispose()
        }
    }

    @Synchronized
    fun restoreConfirmed(): RestoredConfirmedExchange? {
        val current = pending
        if (current?.confirmed == true) {
            return RestoredConfirmedExchange(
                sas = current.sas ?: throw PairingActivationException(),
                intent = current.intent.copyOf(),
                canonicalServerBaseUrl = current.canonicalServerBaseUrl,
            )
        }
        if (current != null) return null
        val recovered = recoveryVault.restore() ?: return null
        try {
            val replacement = PendingExchange(
                intent = recovered.intent.copyOf(),
                canonicalServerBaseUrl = recovered.canonicalServerBaseUrl,
                sendKey = recovered.sendKey.copyOf(),
                receiveKey = recovered.receiveKey.copyOf(),
                confirmed = true,
                sas = recovered.sas,
            )
            pending = replacement
            return RestoredConfirmedExchange(
                sas = recovered.sas,
                intent = recovered.intent.copyOf(),
                canonicalServerBaseUrl = recovered.canonicalServerBaseUrl,
            )
        } finally {
            recovered.dispose()
        }
    }

    private fun decodeExact(value: String, expectedSize: Int): ByteArray {
        val decoded = decodeBounded(value, expectedSize, expectedSize)
        if (decoded.size != expectedSize) {
            decoded.fill(0)
            throw PairingActivationException()
        }
        return decoded
    }

    private fun decodeBounded(value: String, minimumSize: Int, maximumSize: Int): ByteArray {
        if (!BASE64URL.matches(value)) throw PairingActivationException()
        val decoded = try {
            Base64.decode(value, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            throw PairingActivationException()
        }
        if (decoded.size !in minimumSize..maximumSize || encode(decoded) != value) {
            decoded.fill(0)
            throw PairingActivationException()
        }
        return decoded
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
    )

    private class PendingExchange(
        val intent: ByteArray,
        val canonicalServerBaseUrl: String,
        val sendKey: ByteArray,
        val receiveKey: ByteArray,
        var confirmed: Boolean = false,
        var sas: String? = null,
    ) {

        fun dispose() {
            intent.fill(0)
            sendKey.fill(0)
            receiveKey.fill(0)
        }
    }

    internal data class RestoredConfirmedExchange(
        val sas: String,
        val intent: ByteArray,
        val canonicalServerBaseUrl: String,
    ) {
        fun dispose() = intent.fill(0)
    }

    private companion object {
        const val INTENT_BYTES = 16
        const val NONCE_BYTES = 24
        const val TAG_BYTES = 16
        const val MAXIMUM_RESPONSE_CIPHERTEXT_BYTES = 8192
        val BASE64URL = Regex("^[A-Za-z0-9_-]+$")
    }
}

internal object PairingV2CompletionEnvelope {
    private const val INTENT_BYTES = 16
    private const val DOMAIN = "openpaycongo/pairing/complete-response/v2"

    fun responseAad(intent: ByteArray): ByteArray {
        if (intent.size != INTENT_BYTES) throw PairingActivationException()
        val domain = DOMAIN.toByteArray(StandardCharsets.UTF_8)
        try {
            return ByteBuffer.allocate(2 + domain.size + 2 + intent.size)
                .putShort(domain.size.toShort())
                .put(domain)
                .putShort(intent.size.toShort())
                .put(intent)
                .array()
        } finally {
            domain.fill(0)
        }
    }
}

internal object PairingV2CompletionResponse {
    fun readSas(plaintext: ByteArray): String = try {
        val value = JSONObject(String(plaintext, StandardCharsets.UTF_8))
        val state = value.opt("state")
        val sas = value.opt("short_authentication_code")
        if (value.length() != 2 || state !is String || state != "pending_confirmation" || sas !is String) {
            throw PairingActivationException()
        }
        if (!SAS.matches(sas)) throw PairingActivationException()
        sas
    } catch (_: PairingActivationException) {
        throw PairingActivationException()
    } catch (_: Exception) {
        throw PairingActivationException()
    }

    private val SAS = Regex("^[0-9]{6}$")
}

internal object PairingV2Native {
    init {
        System.loadLibrary("openpay_activation")
    }

    external fun begin(intent: ByteArray, serverPublicKey: ByteArray, pairingSecret: ByteArray): Array<ByteArray>?
}
