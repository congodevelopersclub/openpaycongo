package com.congodeveloperclub.opencongopay.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.net.URI
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
 * The activation credential, installation identity, and directional keys are
 * one installed pairing generation. They must never be persisted independently:
 * a reader sees the complete old generation or the complete promoted generation.
 */
internal object PairingDirectionalKeyFormat {
    const val KEY_BYTES = 32
    const val INSTALLATION_ID_BYTES = 16
    private const val CREDENTIAL_LENGTH_BYTES = 2
    private const val SERVER_BASE_URL_LENGTH_BYTES = 2
    private const val RECORD_VERSION: Byte = 5
    private const val ACKNOWLEDGEMENT_PENDING: Byte = 0
    private const val ACKNOWLEDGEMENT_CONFIRMED: Byte = 1
    private const val V4_RECORD_VERSION: Byte = 4
    private const val LEGACY_KEY_ONLY_RECORD_VERSION: Byte = 1
    private const val LEGACY_IDENTITY_RECORD_VERSION: Byte = 2

    fun copyRecord(
        credential: PairingActivationCredential,
        canonicalServerBaseUrl: String,
        sendKey: ByteArray,
        receiveKey: ByteArray,
    ): ByteArray {
        if (sendKey.size != KEY_BYTES || receiveKey.size != KEY_BYTES) {
            throw PairingDirectionalKeyStorageException()
        }
        val installation = try {
            UUID.fromString(credential.installationId)
        } catch (_: Exception) {
            throw PairingDirectionalKeyStorageException()
        }
        val bearerToken = credential.bearerToken.toByteArray(StandardCharsets.UTF_8)
        val serverBaseUrl = PairingServerAuthority.canonicalize(canonicalServerBaseUrl)
            .toByteArray(StandardCharsets.UTF_8)
        try {
            if (bearerToken.size !in 1..8192 ||
                credential.bearerToken.any { it.code <= 0x20 || it.code == 0x7f } ||
                serverBaseUrl.size !in 1..512
            ) throw PairingDirectionalKeyStorageException()
            val fixedBytes = fixedBytes()
            return ByteArray(fixedBytes + bearerToken.size + serverBaseUrl.size).also { record ->
                record[0] = RECORD_VERSION
                record[1] = ACKNOWLEDGEMENT_PENDING
                ByteBuffer.wrap(record, installationIdOffset(), INSTALLATION_ID_BYTES)
                    .putLong(installation.mostSignificantBits)
                    .putLong(installation.leastSignificantBits)
                val sendKeyStart = sendKeyOffset()
                System.arraycopy(sendKey, 0, record, sendKeyStart, KEY_BYTES)
                System.arraycopy(receiveKey, 0, record, sendKeyStart + KEY_BYTES, KEY_BYTES)
                ByteBuffer.wrap(record, sendKeyStart + (KEY_BYTES * 2), CREDENTIAL_LENGTH_BYTES)
                    .putShort(bearerToken.size.toShort())
                System.arraycopy(bearerToken, 0, record, fixedBytes, bearerToken.size)
                ByteBuffer.wrap(record, fixedBytes - SERVER_BASE_URL_LENGTH_BYTES, SERVER_BASE_URL_LENGTH_BYTES)
                    .putShort(serverBaseUrl.size.toShort())
                System.arraycopy(serverBaseUrl, 0, record, fixedBytes + bearerToken.size, serverBaseUrl.size)
            }
        } finally {
            bearerToken.fill(0)
            serverBaseUrl.fill(0)
        }
    }

    fun outboundMaterial(record: ByteArray): PairingOutboundMaterial {
        val metadata = activeMetadata(record)
        if (!metadata.activationAcknowledged) throw PairingActivationException()
        val sendKeyStart = sendKeyOffset()
        return PairingOutboundMaterial(
            installationId = metadata.installationId,
            canonicalServerBaseUrl = metadata.canonicalServerBaseUrl,
            sendKey = record.copyOfRange(sendKeyStart, sendKeyStart + KEY_BYTES),
        )
    }

    fun inboundMaterial(record: ByteArray): PairingInboundMaterial {
        val metadata = activeMetadata(record)
        if (!metadata.activationAcknowledged) throw PairingActivationException()
        val receiveKeyStart = receiveKeyOffset()
        return PairingInboundMaterial(
            installationId = metadata.installationId,
            receiveKey = record.copyOfRange(receiveKeyStart, receiveKeyStart + KEY_BYTES),
        )
    }

    fun pendingActivationAcknowledgementOutboundMaterial(record: ByteArray): PairingOutboundMaterial {
        val metadata = activeMetadata(record)
        if (metadata.activationAcknowledged) throw PairingActivationException()
        return PairingOutboundMaterial(
            installationId = metadata.installationId,
            canonicalServerBaseUrl = metadata.canonicalServerBaseUrl,
            sendKey = record.copyOfRange(sendKeyOffset(), sendKeyOffset() + KEY_BYTES),
        )
    }

    fun pendingActivationAcknowledgementInboundMaterial(record: ByteArray): PairingInboundMaterial {
        val metadata = activeMetadata(record)
        if (metadata.activationAcknowledged) throw PairingActivationException()
        return PairingInboundMaterial(
            installationId = metadata.installationId,
            receiveKey = record.copyOfRange(receiveKeyOffset(), receiveKeyOffset() + KEY_BYTES),
        )
    }

    fun activationAcknowledgementPending(record: ByteArray): Boolean =
        !activeMetadata(record).activationAcknowledged

    fun markActivationAcknowledged(record: ByteArray) {
        val metadata = activeMetadata(record)
        if (!metadata.activationAcknowledged) record[1] = ACKNOWLEDGEMENT_CONFIRMED
    }

    fun isV4Record(record: ByteArray): Boolean = record.firstOrNull() == V4_RECORD_VERSION

    /**
     * V4 already protected the complete credential, origin, and directional
     * keys in the same authenticated Keystore record. Preserve that material,
     * but require the encrypted server acknowledgement before normal traffic.
     */
    fun migrateV4ToV5(record: ByteArray): ByteArray {
        v4Metadata(record)
        return ByteArray(record.size + 1).also { migrated ->
            migrated[0] = RECORD_VERSION
            migrated[1] = ACKNOWLEDGEMENT_PENDING
            System.arraycopy(record, 1, migrated, installationIdOffset(), record.size - 1)
            activeMetadata(migrated)
        }
    }

    private fun activeMetadata(record: ByteArray): PairingActiveRecordMetadata {
        val fixedBytes = fixedBytes()
        if (record.size < fixedBytes || record[0] != RECORD_VERSION ||
            record[1] !in setOf(ACKNOWLEDGEMENT_PENDING, ACKNOWLEDGEMENT_CONFIRMED)
        ) {
            throw PairingActivationException()
        }
        val bearerTokenBytes = ByteBuffer
            .wrap(record, fixedBytes - CREDENTIAL_LENGTH_BYTES - SERVER_BASE_URL_LENGTH_BYTES, CREDENTIAL_LENGTH_BYTES)
            .short
            .toInt() and 0xffff
        val serverBaseUrlBytes = ByteBuffer
            .wrap(record, fixedBytes - SERVER_BASE_URL_LENGTH_BYTES, SERVER_BASE_URL_LENGTH_BYTES)
            .short
            .toInt() and 0xffff
        if (bearerTokenBytes !in 1..8192 || serverBaseUrlBytes !in 1..512 ||
            record.size != fixedBytes + bearerTokenBytes + serverBaseUrlBytes
        ) throw PairingActivationException()
        val installation = ByteBuffer.wrap(record, installationIdOffset(), INSTALLATION_ID_BYTES).run {
            UUID(long, long).toString()
        }
        val serverBaseUrl = String(record, fixedBytes + bearerTokenBytes, serverBaseUrlBytes, StandardCharsets.UTF_8)
        return PairingActiveRecordMetadata(
            installation,
            PairingServerAuthority.canonicalize(serverBaseUrl),
            record[1] == ACKNOWLEDGEMENT_CONFIRMED,
        )
    }

    private fun v4Metadata(record: ByteArray): PairingActiveRecordMetadata {
        val fixedBytes = v4FixedBytes()
        if (record.size < fixedBytes || record[0] != V4_RECORD_VERSION) throw PairingActivationException()
        val bearerTokenBytes = ByteBuffer
            .wrap(record, fixedBytes - CREDENTIAL_LENGTH_BYTES - SERVER_BASE_URL_LENGTH_BYTES, CREDENTIAL_LENGTH_BYTES)
            .short
            .toInt() and 0xffff
        val serverBaseUrlBytes = ByteBuffer
            .wrap(record, fixedBytes - SERVER_BASE_URL_LENGTH_BYTES, SERVER_BASE_URL_LENGTH_BYTES)
            .short
            .toInt() and 0xffff
        if (bearerTokenBytes !in 1..8192 || serverBaseUrlBytes !in 1..512 ||
            record.size != fixedBytes + bearerTokenBytes + serverBaseUrlBytes
        ) throw PairingActivationException()
        val installation = ByteBuffer.wrap(record, 1, INSTALLATION_ID_BYTES).run {
            UUID(long, long).toString()
        }
        val serverBaseUrl = String(record, fixedBytes + bearerTokenBytes, serverBaseUrlBytes, StandardCharsets.UTF_8)
        return PairingActiveRecordMetadata(
            installation,
            PairingServerAuthority.canonicalize(serverBaseUrl),
            false,
        )
    }

    private fun fixedBytes(): Int =
        1 + 1 + INSTALLATION_ID_BYTES + (KEY_BYTES * 2) + CREDENTIAL_LENGTH_BYTES + SERVER_BASE_URL_LENGTH_BYTES

    private fun v4FixedBytes(): Int =
        1 + INSTALLATION_ID_BYTES + (KEY_BYTES * 2) + CREDENTIAL_LENGTH_BYTES + SERVER_BASE_URL_LENGTH_BYTES

    private fun installationIdOffset(): Int = 2

    private fun sendKeyOffset(): Int = installationIdOffset() + INSTALLATION_ID_BYTES

    private fun receiveKeyOffset(): Int = sendKeyOffset() + KEY_BYTES

    fun legacyGeneration(
        credentialInstallationId: String,
        record: ByteArray,
    ): PairingDirectionalKeyGeneration {
        return when {
            record.size == 1 + (KEY_BYTES * 2) && record[0] == LEGACY_KEY_ONLY_RECORD_VERSION ->
                PairingDirectionalKeyGeneration(
                    installationId = credentialInstallationId,
                    sendKey = record.copyOfRange(1, 1 + KEY_BYTES),
                    receiveKey = record.copyOfRange(1 + KEY_BYTES, 1 + (KEY_BYTES * 2)),
                )
            record.size == 1 + INSTALLATION_ID_BYTES + (KEY_BYTES * 2) &&
                record[0] == LEGACY_IDENTITY_RECORD_VERSION -> {
                val installation = ByteBuffer.wrap(record, 1, INSTALLATION_ID_BYTES).run {
                    UUID(long, long).toString()
                }
                if (installation != credentialInstallationId) throw PairingActivationException()
                val sendKeyStart = 1 + INSTALLATION_ID_BYTES
                PairingDirectionalKeyGeneration(
                    installationId = installation,
                    sendKey = record.copyOfRange(sendKeyStart, sendKeyStart + KEY_BYTES),
                    receiveKey = record.copyOfRange(
                        sendKeyStart + KEY_BYTES,
                        sendKeyStart + (KEY_BYTES * 2),
                    ),
                )
            }
            else -> throw PairingActivationException()
        }
    }
}

internal class PairingOutboundMaterial(
    val installationId: String,
    val canonicalServerBaseUrl: String,
    val sendKey: ByteArray,
) {
    fun dispose() = sendKey.fill(0)
}

internal class PairingInboundMaterial(
    val installationId: String,
    val receiveKey: ByteArray,
) {
    fun dispose() = receiveKey.fill(0)
}

private class PairingActiveRecordMetadata(
    val installationId: String,
    val canonicalServerBaseUrl: String,
    val activationAcknowledged: Boolean,
)

/** The signed QR owns this public route; active pairing storage pins its exact origin. */
internal object PairingServerAuthority {
    fun canonicalize(value: String): String {
        val uri = try {
            URI(value)
        } catch (_: Exception) {
            throw PairingDirectionalKeyStorageException()
        }
        val host = uri.host ?: throw PairingDirectionalKeyStorageException()
        if (uri.scheme != "https" || host.isEmpty() || uri.userInfo != null ||
            !uri.rawPath.isNullOrEmpty() || uri.rawQuery != null || uri.rawFragment != null ||
            (uri.port != -1 && uri.port !in 1..65535)
        ) throw PairingDirectionalKeyStorageException()
        val canonical = try {
            URI("https", null, host, uri.port, null, null, null).toASCIIString()
        } catch (_: Exception) {
            throw PairingDirectionalKeyStorageException()
        }
        if (value != canonical) throw PairingDirectionalKeyStorageException()
        return canonical
    }
}

internal class PairingDirectionalKeyGeneration(
    val installationId: String,
    val sendKey: ByteArray,
    val receiveKey: ByteArray,
) {
    fun dispose() {
        sendKey.fill(0)
        receiveKey.fill(0)
    }
}

/**
 * Stores the active pairing generation. The credential, installation identity,
 * and directional keys are copied into one versioned record, AEAD-encrypted
 * with a non-exportable Android Keystore AES key, then atomically replaced in
 * no-backup storage. No Flutter/Dart key-read API exists.
 */
internal class PairingDirectionalKeyVault(private val context: Context) {
    private val recordFile = File(context.noBackupFilesDir, RECORD_FILE)
    private val atomicFile = AtomicFile(recordFile)
    private val legacyRecordFile = File(context.noBackupFilesDir, LEGACY_RECORD_FILE)
    private val legacyAtomicFile = AtomicFile(legacyRecordFile)
    private val legacyCredentialVault = LegacyPairingActivationCredentialVault(context)

    fun save(
        credential: PairingActivationCredential,
        canonicalServerBaseUrl: String,
        sendKey: ByteArray,
        receiveKey: ByteArray,
    ) = synchronized(STORAGE_LOCK) {
        writeActiveGeneration(credential, canonicalServerBaseUrl, sendKey, receiveKey)
    }

    /** Native-only outbound-envelope read. Never exposed to Flutter. */
    fun readOutboundMaterial(): PairingOutboundMaterial = synchronized(STORAGE_LOCK) {
        val record = readActiveRecord()
        try {
            PairingDirectionalKeyFormat.outboundMaterial(record)
        } finally {
            record.fill(0)
        }
    }

    /** Native-only response-envelope read. Never exposed to Flutter. */
    fun readInboundMaterial(): PairingInboundMaterial = synchronized(STORAGE_LOCK) {
        val record = readActiveRecord()
        try {
            PairingDirectionalKeyFormat.inboundMaterial(record)
        } finally {
            record.fill(0)
        }
    }

    /** Only the encrypted activation acknowledgement may use pending material. */
    fun readPendingActivationAcknowledgementOutboundMaterial(): PairingOutboundMaterial = synchronized(STORAGE_LOCK) {
        val record = readActiveRecord()
        try {
            PairingDirectionalKeyFormat.pendingActivationAcknowledgementOutboundMaterial(record)
        } finally {
            record.fill(0)
        }
    }

    /** Only the encrypted activation acknowledgement response may use this key. */
    fun readPendingActivationAcknowledgementInboundMaterial(): PairingInboundMaterial = synchronized(STORAGE_LOCK) {
        val record = readActiveRecord()
        try {
            PairingDirectionalKeyFormat.pendingActivationAcknowledgementInboundMaterial(record)
        } finally {
            record.fill(0)
        }
    }

    /** `null` means no active generation; `false` means durable pending acknowledgement. */
    fun activationAcknowledgementState(): Boolean? = synchronized(STORAGE_LOCK) {
        if (!recordFile.exists() && !File(recordFile.path + ".bak").exists()) return@synchronized null
        val record = readActiveRecord()
        try {
            !PairingDirectionalKeyFormat.activationAcknowledgementPending(record)
        } finally {
            record.fill(0)
        }
    }

    /** Mark active only after native authentication of the encrypted response. */
    fun markActivationAcknowledged() = synchronized(STORAGE_LOCK) {
        val record = readActiveRecord()
        try {
            PairingDirectionalKeyFormat.markActivationAcknowledged(record)
            writeEncryptedRecord(record)
        } finally {
            record.fill(0)
        }
    }

    private fun writeActiveGeneration(
        credential: PairingActivationCredential,
        canonicalServerBaseUrl: String,
        sendKey: ByteArray,
        receiveKey: ByteArray,
    ) {
        val plaintext = PairingDirectionalKeyFormat.copyRecord(
            credential,
            canonicalServerBaseUrl,
            sendKey,
            receiveKey,
        )
        try {
            writeEncryptedRecord(plaintext)
        } finally {
            plaintext.fill(0)
        }
    }

    private fun writeEncryptedRecord(plaintext: ByteArray) {
        val nonce = ByteArray(GCM_NONCE_BYTES).also(SecureRandom()::nextBytes)
        var ciphertext = ByteArray(0)
        var payload = ByteArray(0)
        var output: java.io.FileOutputStream? = null
        try {
            ciphertext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(
                    Cipher.ENCRYPT_MODE,
                    keyForWrite(),
                    GCMParameterSpec(GCM_TAG_BITS, nonce),
                )
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
            nonce.fill(0)
            ciphertext.fill(0)
            payload.fill(0)
        }
    }

    private fun readActiveRecord(): ByteArray {
        if (recordFile.exists() || File(recordFile.path + ".bak").exists()) {
            val record = decryptRecord(atomicFile, keyForExisting(KEY_ALIAS), AAD)
            if (!PairingDirectionalKeyFormat.isV4Record(record)) return record
            try {
                val migrated = PairingDirectionalKeyFormat.migrateV4ToV5(record)
                try {
                    writeEncryptedRecord(migrated)
                    return migrated
                } catch (_: Exception) {
                    migrated.fill(0)
                    throw PairingActivationException()
                }
            } finally {
                record.fill(0)
            }
        }
        return migrateLegacyGeneration()
    }

    /**
     * Earlier releases wrote two authenticated records. The shipped v1 key
     * record has no identity, so it is bound to the separately authenticated
     * credential. A short-lived v2 identity record is also accepted only when
     * its embedded identity agrees with that credential.
     */
    private fun migrateLegacyGeneration(): ByteArray {
        // Earlier records contain no QR-derived server origin. Promoting them
        // would grant a caller authority to choose the mobile-envelope route.
        // Recovery must re-pair and obtain a freshly signature-verified QR.
        throw PairingActivationException()
    }

    private fun decryptRecord(
        source: AtomicFile,
        key: SecretKey,
        aad: ByteArray,
    ): ByteArray {
        val payload = try {
            source.openRead().use { it.readBytes() }
        } catch (_: Exception) {
            throw PairingActivationException()
        }
        var nonce = ByteArray(0)
        var ciphertext = ByteArray(0)
        try {
            if (payload.size <= 13 || payload[0] != ENVELOPE_VERSION) throw PairingActivationException()
            nonce = payload.copyOfRange(1, 1 + GCM_NONCE_BYTES)
            ciphertext = payload.copyOfRange(1 + GCM_NONCE_BYTES, payload.size)
            return Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
                updateAAD(aad)
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

    private fun keyForExisting(alias: String): SecretKey {
        val store = try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        } catch (_: Exception) {
            throw PairingActivationException()
        }
        return try {
            (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey
                ?: throw PairingActivationException()
        } catch (_: PairingActivationException) {
            throw PairingActivationException()
        } catch (_: Exception) {
            throw PairingActivationException()
        }
    }

    private companion object {
        val STORAGE_LOCK = Any()
        const val RECORD_FILE = "pairing_active_generation_v1"
        const val KEY_ALIAS = "openpaycongo.pairing.active-generation.v1"
        const val LEGACY_RECORD_FILE = "pairing_directional_keys_v1"
        const val LEGACY_KEY_ALIAS = "openpaycongo.pairing.directional-keys.v1"
        const val ENVELOPE_VERSION: Byte = 1
        const val GCM_NONCE_BYTES = 12
        const val GCM_TAG_BITS = 128
        val AAD = "openpaycongo/pairing/active-generation/v1"
            .toByteArray(StandardCharsets.US_ASCII)
        val LEGACY_AAD = "openpaycongo/pairing/directional-keys/v1"
            .toByteArray(StandardCharsets.US_ASCII)
    }
}
