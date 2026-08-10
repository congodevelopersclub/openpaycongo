package com.congodeveloperclub.opencongopay.sms

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

internal object SmsHealthProjection {
    fun forFlutter(
        health: CaptureHealth,
        decisions: DecisionJournalStatus?,
        journalRecoveryRequired: Boolean,
    ): Map<String, Any?> {
        val recoveryRequired = journalRecoveryRequired ||
            health.fault == CaptureFaultCode.corruption ||
            health.fault == CaptureFaultCode.keyInvalidated
        val visibleDecisions = if (recoveryRequired) null else decisions

        return mapOf(
            "fault" to health.fault?.name,
            "occurred_at_ms" to health.occurredAtMillis,
            "missed" to health.missed?.name,
            "missed_at_ms" to health.missedAtMillis,
            "decision_count" to visibleDecisions?.count,
            "decision_encrypted_bytes" to visibleDecisions?.encryptedBytes,
            "recovery_required" to recoveryRequired,
        )
    }
}

internal class EncryptedSmsVault(context: Context) {
    companion object {
        private const val RULES_ALIAS = "openpay_sms_rules_v3"
        private const val INBOX_ALIAS = "openpay_sms_inbox_v3"
    }

    private val root = File(context.noBackupFilesDir, "trusted_sms_v3").also {
        LegacySmsStorageGuard.requireNoCiphertext(File(context.noBackupFilesDir, "trusted_sms_v2"))
        SmsCiphertextInventory.requireNoUnclassifiedQuarantine(it)
    }
    private val rulesAccess = AndroidKeystoreKeyAccess(RULES_ALIAS) {
        SmsCiphertextInventory.exists(root, SmsCiphertextDomain.rules)
    }
    private val inboxAccess = AndroidKeystoreKeyAccess(INBOX_ALIAS) {
        SmsCiphertextInventory.exists(root, SmsCiphertextDomain.inbox)
    }
    private val queue = AtomicSmsQueue(
        root,
        AesGcmEnvelopeCrypto(rulesAccess, "rules-v3"),
        AesGcmEnvelopeCrypto(inboxAccess, "inbox-v3"),
        JvmAtomicFileOps(AndroidDirectorySync()),
    )

    fun replaceTrustedSenders(values: List<String>) = queue.replaceTrustedSenders(values)
    fun addTrustedSender(value: String): List<String> = queue.addTrustedSender(value)
    fun trustedSenders(): List<String> = queue.trustedSenders()
    fun clearTrustedSenders(): List<String> = queue.clearTrustedSenders()
    fun revokeTrustedSender(value: String): List<String> = queue.revokeTrustedSender(value)
    fun isTrustedSender(sender: String): Boolean = queue.isTrustedSender(sender)
    fun persistIfAbsent(record: TrustedSmsRecord): PersistResult = queue.persistIfAbsent(record)
    fun health(): CaptureHealth = queue.health()
    fun recordFault(code: CaptureFaultCode) = queue.recordFault(code)
    fun recordMissSignal(reason: CaptureMissReason) = queue.recordMissSignal(reason)

    fun recordsForFlutter(): List<Map<String, Any>> = queue.records().map {
        mapOf(
            "id" to it.id,
            "sender" to it.sender,
            "received_at_ms" to it.receivedAtMillis,
            "segments" to it.segments,
            "body" to it.body,
        )
    }

    fun commitDecision(id: String, decision: CaptureDecision) = queue.commitDecision(id, decision)
    fun probeStorage(): Boolean = queue.probeStorage()

    fun decisionsForFlutter(limit: Int, cursor: String?): Map<String, Any?> {
        val page = queue.exportDecisions(limit, cursor)
        return mapOf(
            "records" to page.records.map {
                mapOf(
                    "id" to it.id,
                    "decision" to it.decision.name,
                    "decided_at_ms" to it.decidedAtMillis,
                )
            },
            "next_cursor" to page.nextCursor,
            "truncated" to page.truncated,
        )
    }

    fun healthForFlutter(): Map<String, Any?> {
        var journalRecoveryRequired = false
        val decisions: DecisionJournalStatus? = try {
            queue.decisionStatus()
        } catch (_: RecoveryRequiredException) {
            journalRecoveryRequired = true
            null
        }
        val health = queue.health()
        return SmsHealthProjection.forFlutter(
            health = health,
            decisions = decisions,
            journalRecoveryRequired = journalRecoveryRequired,
        )
    }

    internal fun digest(record: TrustedSmsRecord): String {
        val framed = listOf(
            record.sender,
            record.receivedAtMillis.toString(),
            record.segments.toString(),
            record.body,
        ).joinToString("|") { value -> "${value.toByteArray(StandardCharsets.UTF_8).size}:$value" }
        return Base64.encodeToString(
            MessageDigest.getInstance("SHA-256").digest(framed.toByteArray(StandardCharsets.UTF_8)),
            Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE,
        )
    }
}

private class AndroidDirectorySync : DirectorySync {
    override fun sync(directory: File) {
        val descriptor = Os.open(
            directory.absolutePath,
            OsConstants.O_RDONLY,
            0,
        )
        try {
            Os.fsync(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }
}

private class AndroidKeystoreKeyAccess(
    private val alias: String,
    private val ciphertextExists: () -> Boolean,
) : SecretKeyAccess {
    override fun keyForEncrypt(): SecretKey {
        existingOrInvalidated()?.let { return it }
        if (ciphertextExists()) {
            throw KeyInvalidatedException()
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    override fun keyForDecrypt(): SecretKey = existingOrInvalidated() ?: throw KeyInvalidatedException()

    private fun existingOrInvalidated(): SecretKey? = try {
        existing()
    } catch (error: Exception) {
        if (ciphertextExists()) {
            throw KeyInvalidatedException(error)
        }
        throw error
    }

    private fun existing(): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return store.getKey(alias, null) as? SecretKey
    }
}

internal object SmsVaultProvider {
    @Volatile private var instance: EncryptedSmsVault? = null

    fun get(context: Context): EncryptedSmsVault = instance ?: synchronized(this) {
        instance ?: EncryptedSmsVault(context.applicationContext).also { instance = it }
    }
}
