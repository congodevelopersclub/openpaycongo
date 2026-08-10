package com.congodeveloperclub.opencongopay.sms

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

internal data class TrustedSmsRecord(
    val id: String,
    val sender: String,
    val receivedAtMillis: Long,
    val segments: Int,
    val body: String,
)

internal enum class PersistResult { stored, duplicate, decided, faulted }
internal enum class CaptureDecision { reviewed, rejected, processed }
internal data class DecisionRecord(val decision: CaptureDecision, val decidedAtMillis: Long)
internal data class DecisionExportRecord(val id: String, val decision: CaptureDecision, val decidedAtMillis: Long)
internal data class DecisionJournalStatus(val count: Int, val encryptedBytes: Long)
internal data class DecisionExportPage(
    val records: List<DecisionExportRecord>,
    val nextCursor: String?,
    val truncated: Boolean,
)
private data class DecisionManifest(
    val count: Int,
    val encryptedBytes: Long,
    val segment: Int,
    val segmentCount: Int,
)
private data class PendingDecision(
    val id: String,
    val sourceId: String,
    val record: DecisionRecord,
    val encryptedBytes: Long,
    val segment: Int,
    val offset: Int,
    val targetCount: Int,
    val targetEncryptedBytes: Long,
)
internal enum class CaptureFaultCode { capacity, storage, corruption, keyInvalidated }
internal data class CaptureHealth(
    val fault: CaptureFaultCode?,
    val occurredAtMillis: Long?,
    val missed: CaptureMissReason?,
    val missedAtMillis: Long?,
)
internal class SmsStorageException(cause: Throwable? = null) : Exception(cause)
internal class DecisionConflictException(
    val existing: CaptureDecision,
    val requested: CaptureDecision,
) : Exception("decision_conflict")
internal class InvalidDecisionCursorException : Exception("invalid_cursor")
internal class LegacySmsMigrationRequiredException : Exception("legacy_migration_required")
internal class RecoveryRequiredException(cause: Throwable? = null) : Exception("recovery_required", cause)

internal interface AtomicFileOps {
    fun ensureDirectory(directory: File) {
        require(directory.isDirectory || directory.mkdirs())
    }
    fun writeAtomic(file: File, bytes: ByteArray)
    fun read(file: File): ByteArray
    fun delete(file: File): Boolean
    fun quarantine(file: File, directory: File, domain: SmsCiphertextDomain): Boolean
}

internal fun interface DirectorySync {
    fun sync(directory: File)
}

internal class JvmAtomicFileOps(
    private val directorySync: DirectorySync = DirectorySync {},
) : AtomicFileOps {
    override fun ensureDirectory(directory: File) {
        if (directory.isDirectory) return
        if (!directory.mkdirs()) throw IllegalStateException("directory_create_failed")
        directory.parentFile?.let(directorySync::sync)
    }

    override fun writeAtomic(file: File, bytes: ByteArray) {
        require(bytes.isNotEmpty())
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, ".${file.name}.tmp")
        FileOutputStream(temporary).use { stream ->
            stream.write(bytes)
            stream.fd.sync()
        }
        if (!temporary.renameTo(file)) {
            temporary.delete()
            throw IllegalStateException("atomic_rename_failed")
        }
        directorySync.sync(file.parentFile ?: throw IllegalStateException("missing_parent"))
    }

    override fun read(file: File): ByteArray = file.readBytes()
    override fun delete(file: File): Boolean {
        if (!file.exists()) return true
        val deleted = file.delete()
        if (deleted) directorySync.sync(file.parentFile ?: throw IllegalStateException("missing_parent"))
        return deleted
    }

    override fun quarantine(file: File, directory: File, domain: SmsCiphertextDomain): Boolean {
        directory.mkdirs()
        val sourceDirectory = file.parentFile ?: return false
        val moved = file.renameTo(File(directory, "${domain.name}--${file.name}.${System.nanoTime()}.bad"))
        if (moved) {
            directorySync.sync(sourceDirectory)
            if (directory != sourceDirectory) directorySync.sync(directory)
        }
        return moved
    }
}

internal class AtomicSmsQueue(
    private val root: File,
    private val rulesCrypto: EnvelopeCrypto,
    private val inboxCrypto: EnvelopeCrypto,
    private val files: AtomicFileOps = JvmAtomicFileOps(),
    private val maxRows: Int = 500,
    private val maxBytes: Long = 2L * 1024L * 1024L,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    companion object {
        private const val SCHEMA = "v3"
        private const val MAX_RULES = 64
        private const val DECISIONS_PER_SEGMENT = 64
        private val CURSOR = Regex("^v3:([0-9]{1,10}):([0-9]{1,2})$")
    }

    private val inboxDirectory = File(root, "inbox")
    private val decisionDirectory = File(root, "decisions")
    private val decisionIndexDirectory = File(root, "decision-index")
    private val quarantineDirectory = File(root, "quarantine")
    private val rulesFile = File(root, "rules.enc")
    private val faultFile = File(root, "fault.state")
    private val missFile = File(root, "miss.state")
    private val probeFile = File(root, "storage.probe")
    private val decisionManifestFile = File(root, "decision-manifest.enc")
    private val decisionPendingFile = File(root, "decision-pending.enc")
    private val journalRecoveryMarkerFile = File(root, "journal-recovery-required.state")

    init {
        require(maxRows in 1..1000)
        require(maxBytes in 4096L..8L * 1024L * 1024L)
        files.ensureDirectory(root)
        files.ensureDirectory(inboxDirectory)
        files.ensureDirectory(decisionDirectory)
        files.ensureDirectory(decisionIndexDirectory)
        files.ensureDirectory(quarantineDirectory)
    }

    @Synchronized
    fun replaceTrustedSenders(values: List<String>) {
        require(values.size <= MAX_RULES)
        val normalized = values.map { SenderRules.normalize(it) ?: throw IllegalArgumentException() }.distinct().sorted()
        require(normalized.size == values.size)
        val cleartext = normalized.joinToString("\n").toByteArray(StandardCharsets.US_ASCII)
        try {
            files.writeAtomic(rulesFile, rulesCrypto.encrypt("rules", "trusted-senders", cleartext))
        } catch (error: Exception) {
            recordFault(classify(error))
            throw SmsStorageException(error)
        }
    }

    @Synchronized
    fun addTrustedSender(value: String): List<String> {
        val normalized = SenderRules.normalize(value) ?: throw IllegalArgumentException()
        val next = (trustedSenders() + normalized).distinct().sorted()
        replaceTrustedSenders(next)
        return next
    }

    @Synchronized
    fun trustedSenders(): List<String> {
        if (!rulesFile.exists()) return emptyList()
        return try {
            decodeTrustedSenders(
                rulesCrypto.decrypt("rules", "trusted-senders", files.read(rulesFile)),
            )
        } catch (error: Exception) {
            files.quarantine(rulesFile, quarantineDirectory, SmsCiphertextDomain.rules)
            recordFault(classify(error))
            throw SmsStorageException(error)
        }
    }

    @Synchronized
    fun clearTrustedSenders(): List<String> {
        replaceTrustedSenders(emptyList())
        return emptyList()
    }

    @Synchronized
    fun revokeTrustedSender(value: String): List<String> {
        val normalized = SenderRules.normalize(value) ?: throw IllegalArgumentException()
        val next = trustedSenders().filterNot { it == normalized }
        replaceTrustedSenders(next)
        return next
    }

    @Synchronized
    fun isTrustedSender(sender: String): Boolean {
        if (!rulesFile.exists()) {
            return false
        }
        return try {
            trustedSenders().contains(sender)
        } catch (_: SmsStorageException) {
            // trustedSenders records and preserves the specific durable fault.
            false
        }
    }

    private fun decodeTrustedSenders(cleartext: ByteArray): List<String> {
        require(cleartext.all { byte -> byte.toInt() in 0..127 })
        val values = String(cleartext, StandardCharsets.US_ASCII)
            .split('\n')
            .filter(String::isNotEmpty)
        require(values.size <= MAX_RULES && values == values.distinct().sorted())
        return values.map { SenderRules.normalize(it) ?: throw IllegalArgumentException() }
    }

    @Synchronized
    fun persistIfAbsent(record: TrustedSmsRecord): PersistResult {
        validate(record)
        val decided = decisionFileForTest(record.id)
        if (decided.exists()) {
            return try {
                readDecision(record.id)
                PersistResult.decided
            } catch (error: Exception) {
                quarantineJournalCiphertext(decided)
                recordFault(classify(error))
                PersistResult.faulted
            }
        }
        val fault = health().fault
        if (fault == CaptureFaultCode.storage && !probeStorage()) {
            return PersistResult.faulted
        }
        if (fault != null && fault != CaptureFaultCode.storage) {
            return PersistResult.faulted
        }
        val target = recordFileForTest(record.id)
        if (target.exists()) {
            return PersistResult.duplicate
        }
        return try {
            val encrypted = inboxCrypto.encrypt("inbox", record.id, encode(record))
            val current = inboxFiles()
            val usedBytes = current.sumOf(File::length)
            if (current.size >= maxRows || usedBytes + encrypted.size > maxBytes) {
                recordFault(CaptureFaultCode.capacity)
                PersistResult.faulted
            } else {
                files.writeAtomic(target, encrypted)
                PersistResult.stored
            }
        } catch (error: Exception) {
            recordFault(classify(error))
            PersistResult.faulted
        }
    }

    @Synchronized
    fun records(): List<TrustedSmsRecord> = inboxFiles().map { file ->
        try {
            decode(inboxCrypto.decrypt("inbox", file.nameWithoutExtension, files.read(file))).also {
                require(it.id == file.nameWithoutExtension)
            }
        } catch (error: Exception) {
            files.quarantine(file, quarantineDirectory, SmsCiphertextDomain.inbox)
            recordFault(classify(error))
            throw SmsStorageException(error)
        }
    }.sortedBy(TrustedSmsRecord::receivedAtMillis)

    @Synchronized
    fun commitDecision(id: String, decision: CaptureDecision) {
        require(id.matches(Regex("^[A-Za-z0-9_-]{43}$")))
        val source = recordFileForTest(id)
        val target = decisionFileForTest(id)
        try {
            recoverPendingDecision()
            if (target.exists()) {
                val existing = try {
                    readDecision(id).decision
                } catch (error: Exception) {
                    quarantineJournalCiphertext(target)
                    recordRecoveryRequired(error)
                }
                if (existing != decision) {
                    throw DecisionConflictException(existing, decision)
                }
            } else {
                if (!source.exists()) {
                    throw SmsStorageException()
                }
                appendDecision(id, DecisionRecord(decision, nowMillis()))
            }
            clearCapacityIfAvailable()
        } catch (error: DecisionConflictException) {
            throw error
        } catch (error: RecoveryRequiredException) {
            throw error
        } catch (error: SmsStorageException) {
            throw error
        } catch (error: Exception) {
            if (journalRecoveryMarkerFile.exists()) {
                throw RecoveryRequiredException(error)
            }
            recordFault(classify(error))
            throw SmsStorageException(error)
        }
    }

    @Synchronized
    fun health(): CaptureHealth {
        if (!faultFile.exists()) {
            val missed = readMiss()
            return CaptureHealth(null, null, missed?.first, missed?.second)
        }
        return try {
            val parts = String(files.read(faultFile), StandardCharsets.US_ASCII).split('|')
            require(parts.size == 3 && parts[0] == SCHEMA)
            val missed = readMiss()
            CaptureHealth(CaptureFaultCode.valueOf(parts[1]), parts[2].toLong(), missed?.first, missed?.second)
        } catch (_: Exception) {
            CaptureHealth(CaptureFaultCode.corruption, null, null, null)
        }
    }

    @Synchronized
    fun probeStorage(): Boolean {
        if (health().fault != CaptureFaultCode.storage) {
            return false
        }
        val sentinel = "openpay-storage-probe-v3".toByteArray(StandardCharsets.US_ASCII)
        return try {
            files.writeAtomic(probeFile, sentinel)
            if (!files.read(probeFile).contentEquals(sentinel)) {
                throw IllegalStateException("storage_probe_mismatch")
            }
            if (!files.delete(probeFile) || !files.delete(faultFile)) {
                throw IllegalStateException("storage_probe_cleanup_failed")
            }
            true
        } catch (_: Exception) {
            try {
                recordFault(CaptureFaultCode.storage)
            } catch (_: Exception) {
                // Health bridge still fails closed when fault storage is unavailable.
            }
            false
        }
    }

    @Synchronized
    fun recordFault(code: CaptureFaultCode) {
        files.writeAtomic(
            faultFile,
            "$SCHEMA|${code.name}|${nowMillis()}".toByteArray(StandardCharsets.US_ASCII),
        )
    }

    @Synchronized
    fun recordMissSignal(reason: CaptureMissReason) {
        files.writeAtomic(
            missFile,
            "$SCHEMA|${reason.name}|${nowMillis()}".toByteArray(StandardCharsets.US_ASCII),
        )
    }

    internal fun recordFileForTest(id: String): File = File(inboxDirectory, "$id.enc")
    internal fun decisionFileForTest(id: String): File = File(decisionDirectory, "$id.enc")
    internal fun decisionIndexFileForTest(segment: Int): File = File(
        decisionIndexDirectory,
        "${segment.toString().padStart(10, '0')}.enc",
    )
    internal fun decisionCountForTest(): Int = decisionStatus().count

    @Synchronized
    fun decisionStatus(): DecisionJournalStatus {
        throwIfJournalRecoveryRequired()
        return try {
            recoverPendingDecision()
            val manifest = readDecisionManifest()
            DecisionJournalStatus(manifest.count, manifest.encryptedBytes)
        } catch (error: Exception) {
            recordRecoveryRequired(error)
        }
    }

    @Synchronized
    fun exportDecisions(limit: Int, cursor: String?): DecisionExportPage {
        throwIfJournalRecoveryRequired()
        require(limit in 1..100)
        val decodedCursor = decodeCursor(cursor)
        return try {
            recoverPendingDecision()
            val manifest = readDecisionManifest()
            if (manifest.count == 0) {
                if (cursor != null) throw InvalidDecisionCursorException()
                return DecisionExportPage(emptyList(), null, false)
            }
            var (segment, offset) = validateCursor(decodedCursor, manifest)
            val records = mutableListOf<DecisionExportRecord>()
            while (records.size < limit && segment <= manifest.segment) {
                val indexed = readDecisionSegment(segment)
                require(offset in 0 until indexed.size)
                while (offset < indexed.size && records.size < limit) {
                    val exported = indexed[offset]
                    val tombstone = try {
                        readDecision(exported.id)
                    } catch (error: Exception) {
                        quarantineJournalCiphertext(decisionFileForTest(exported.id))
                        recordFault(classify(error))
                        throw error
                    }
                    require(tombstone == DecisionRecord(exported.decision, exported.decidedAtMillis))
                    records.add(exported)
                    offset += 1
                }
                if (offset == indexed.size) {
                    segment += 1
                    offset = 0
                }
            }
            val consumed = records.size
            val absoluteCursor = if (segment > manifest.segment) null else encodeCursor(segment, offset)
            if (cursor != null) require(records.isNotEmpty() && absoluteCursor != cursor)
            DecisionExportPage(
                records = records,
                nextCursor = absoluteCursor,
                truncated = consumed < manifest.count && absoluteCursor != null,
            )
        } catch (error: InvalidDecisionCursorException) {
            throw error
        } catch (error: Exception) {
            recordRecoveryRequired(error)
        }
    }

    private fun recordRecoveryRequired(error: Exception): Nothing {
        try {
            markJournalRecoveryRequired()
        } catch (_: Exception) {
            // The original journal failure remains authoritative when marker storage is unavailable.
        }
        try {
            recordFault(classify(error))
        } catch (_: Exception) {
            // The typed recovery result must survive failure to persist fault metadata.
        }
        throw RecoveryRequiredException(error)
    }

    private fun appendDecision(id: String, record: DecisionRecord) {
        val manifest = readDecisionManifest()
        require(manifest.count < Int.MAX_VALUE)
        val segment = if (manifest.segmentCount == DECISIONS_PER_SEGMENT) {
            manifest.segment + 1
        } else {
            manifest.segment
        }
        val offset = if (manifest.segmentCount == DECISIONS_PER_SEGMENT) 0 else manifest.segmentCount
        val tombstone = inboxCrypto.encrypt("decision", id, encodeDecision(record))
        val pending = PendingDecision(
            id = id,
            sourceId = id,
            record = record,
            encryptedBytes = tombstone.size.toLong(),
            segment = segment,
            offset = offset,
            targetCount = manifest.count + 1,
            targetEncryptedBytes = Math.addExact(manifest.encryptedBytes, tombstone.size.toLong()),
        )
        files.writeAtomic(
            decisionPendingFile,
            inboxCrypto.encrypt("decision-pending", "pending", encodePendingDecision(pending)),
        )
        files.writeAtomic(decisionFileForTest(id), tombstone)
        finishPendingDecision(pending)
    }

    private fun recoverPendingDecision() {
        throwIfJournalRecoveryRequired()
        if (!decisionPendingFile.exists()) return
        val pending = try {
            decodePendingDecision(
                inboxCrypto.decrypt(
                    "decision-pending",
                    "pending",
                    files.read(decisionPendingFile),
                ),
            )
        } catch (error: Exception) {
            quarantineJournalCiphertext(decisionPendingFile)
            throw error
        }
        val target = decisionFileForTest(pending.id)
        if (target.exists()) {
            try {
                require(readDecision(pending.id) == pending.record)
                require(target.length() == pending.encryptedBytes)
            } catch (error: Exception) {
                quarantineJournalCiphertext(target)
                recordRecoveryRequired(error)
            }
        } else {
            val encrypted = inboxCrypto.encrypt(
                "decision",
                pending.id,
                encodeDecision(pending.record),
            )
            require(encrypted.size.toLong() == pending.encryptedBytes)
            files.writeAtomic(target, encrypted)
        }
        finishPendingDecision(pending)
    }

    private fun finishPendingDecision(pending: PendingDecision) {
        val segmentRecords = readDecisionSegment(pending.segment).toMutableList()
        require(segmentRecords.size == pending.offset ||
            (segmentRecords.size == pending.offset + 1 && segmentRecords[pending.offset] ==
                DecisionExportRecord(pending.id, pending.record.decision, pending.record.decidedAtMillis)))
        if (segmentRecords.size == pending.offset) {
            segmentRecords.add(
                DecisionExportRecord(pending.id, pending.record.decision, pending.record.decidedAtMillis),
            )
            writeDecisionSegment(pending.segment, segmentRecords)
        }
        writeDecisionManifest(
            DecisionManifest(
                count = pending.targetCount,
                encryptedBytes = pending.targetEncryptedBytes,
                segment = pending.segment,
                segmentCount = pending.offset + 1,
            ),
        )
        val source = recordFileForTest(pending.sourceId)
        if (!files.delete(source)) throw IllegalStateException("source_delete_failed")
        if (!files.delete(decisionPendingFile)) throw IllegalStateException("pending_delete_failed")
    }

    private fun readDecisionManifest(): DecisionManifest {
        if (!decisionManifestFile.exists()) {
            if (SmsCiphertextInventory.journalExists(root)) {
                recordRecoveryRequired(IllegalStateException("missing_decision_manifest"))
            }
            return DecisionManifest(0, 0, 0, 0)
        }
        return try {
            val cleartext = inboxCrypto.decrypt(
                "decision-manifest",
                "manifest",
                files.read(decisionManifestFile),
            )
            val parts = String(cleartext, StandardCharsets.US_ASCII).split('|')
            require(parts.size == 5 && parts[0] == SCHEMA)
            val manifest = DecisionManifest(
                count = parts[1].toInt(),
                encryptedBytes = parts[2].toLong(),
                segment = parts[3].toInt(),
                segmentCount = parts[4].toInt(),
            )
            require(manifest.count >= 0 && manifest.encryptedBytes >= 0 && manifest.segment >= 0)
            require(manifest.segmentCount in 0..DECISIONS_PER_SEGMENT)
            require((manifest.count == 0) == (manifest.segmentCount == 0))
            require(
                manifest.count.toLong() ==
                    manifest.segment.toLong() * DECISIONS_PER_SEGMENT + manifest.segmentCount,
            )
            manifest
        } catch (error: Exception) {
            quarantineJournalCiphertext(decisionManifestFile)
            throw error
        }
    }

    private fun writeDecisionManifest(manifest: DecisionManifest) {
        val cleartext = "$SCHEMA|${manifest.count}|${manifest.encryptedBytes}|${manifest.segment}|${manifest.segmentCount}"
            .toByteArray(StandardCharsets.US_ASCII)
        files.writeAtomic(
            decisionManifestFile,
            inboxCrypto.encrypt("decision-manifest", "manifest", cleartext),
        )
    }

    private fun readDecisionSegment(segment: Int): List<DecisionExportRecord> {
        require(segment >= 0)
        val file = decisionIndexFileForTest(segment)
        if (!file.exists()) return emptyList()
        val identity = "segment-${segment.toString().padStart(10, '0')}"
        return try {
            val cleartext = inboxCrypto.decrypt("decision-index", identity, files.read(file))
            require(cleartext.isNotEmpty())
            String(cleartext, StandardCharsets.US_ASCII).split('\n').map { line ->
                val parts = line.split('|')
                require(parts.size == 3 && parts[0].matches(Regex("^[A-Za-z0-9_-]{43}$")))
                DecisionExportRecord(parts[0], CaptureDecision.valueOf(parts[1]), parts[2].toLong()).also {
                    require(it.decidedAtMillis >= 0)
                }
            }.also { require(it.size <= DECISIONS_PER_SEGMENT) }
        } catch (error: Exception) {
            quarantineJournalCiphertext(file)
            throw error
        }
    }

    private fun writeDecisionSegment(segment: Int, records: List<DecisionExportRecord>) {
        require(records.isNotEmpty() && records.size <= DECISIONS_PER_SEGMENT)
        val identity = "segment-${segment.toString().padStart(10, '0')}"
        val cleartext = records.joinToString("\n") { "${it.id}|${it.decision.name}|${it.decidedAtMillis}" }
            .toByteArray(StandardCharsets.US_ASCII)
        files.writeAtomic(
            decisionIndexFileForTest(segment),
            inboxCrypto.encrypt("decision-index", identity, cleartext),
        )
    }

    private fun encodePendingDecision(pending: PendingDecision): ByteArray = (
        "$SCHEMA|${pending.id}|${pending.sourceId}|${pending.record.decision.name}|${pending.record.decidedAtMillis}|" +
            "${pending.encryptedBytes}|${pending.segment}|${pending.offset}|" +
            "${pending.targetCount}|${pending.targetEncryptedBytes}"
        ).toByteArray(StandardCharsets.US_ASCII)

    private fun decodePendingDecision(cleartext: ByteArray): PendingDecision {
        val parts = String(cleartext, StandardCharsets.US_ASCII).split('|')
        require(parts.size == 10 && parts[0] == SCHEMA)
        val pending = PendingDecision(
            id = parts[1],
            sourceId = parts[2],
            record = DecisionRecord(CaptureDecision.valueOf(parts[3]), parts[4].toLong()),
            encryptedBytes = parts[5].toLong(),
            segment = parts[6].toInt(),
            offset = parts[7].toInt(),
            targetCount = parts[8].toInt(),
            targetEncryptedBytes = parts[9].toLong(),
        )
        require(pending.id.matches(Regex("^[A-Za-z0-9_-]{43}$")))
        require(pending.sourceId == pending.id)
        require(pending.record.decidedAtMillis >= 0 && pending.encryptedBytes > 0)
        require(pending.segment >= 0 && pending.offset in 0 until DECISIONS_PER_SEGMENT)
        require(pending.targetCount > 0 && pending.targetEncryptedBytes >= pending.encryptedBytes)
        return pending
    }

    private fun decodeCursor(cursor: String?): Pair<Int, Int> {
        if (cursor == null) return 0 to 0
        val match = CURSOR.matchEntire(cursor) ?: throw InvalidDecisionCursorException()
        val segment = match.groupValues[1].toIntOrNull() ?: throw InvalidDecisionCursorException()
        val offset = match.groupValues[2].toIntOrNull() ?: throw InvalidDecisionCursorException()
        if (offset !in 0 until DECISIONS_PER_SEGMENT) throw InvalidDecisionCursorException()
        return segment to offset
    }

    private fun validateCursor(cursor: Pair<Int, Int>, manifest: DecisionManifest): Pair<Int, Int> {
        val (segment, offset) = cursor
        if (manifest.count == 0) {
            if (segment != 0 || offset != 0) throw InvalidDecisionCursorException()
            return cursor
        }
        if (segment > manifest.segment) throw InvalidDecisionCursorException()
        val size = if (segment == manifest.segment) manifest.segmentCount else DECISIONS_PER_SEGMENT
        if (offset !in 0 until size) throw InvalidDecisionCursorException()
        return cursor
    }

    private fun encodeCursor(segment: Int, offset: Int): String = "v3:$segment:$offset"

    private fun quarantineJournalCiphertext(file: File) {
        if (!file.exists()) return
        markJournalRecoveryRequired()
        files.quarantine(file, quarantineDirectory, SmsCiphertextDomain.inbox)
    }

    private fun throwIfJournalRecoveryRequired() {
        if (journalRecoveryMarkerFile.exists()) throw RecoveryRequiredException()
    }

    private fun markJournalRecoveryRequired() {
        if (journalRecoveryMarkerFile.exists()) return
        files.writeAtomic(
            journalRecoveryMarkerFile,
            "$SCHEMA|journal-recovery-required".toByteArray(StandardCharsets.US_ASCII),
        )
    }

    private fun inboxFiles(): List<File> = inboxDirectory.listFiles { file -> file.extension == "enc" }?.toList() ?: emptyList()

    private fun clearCapacityIfAvailable() {
        val inbox = inboxFiles()
        if (
            health().fault == CaptureFaultCode.capacity &&
            inbox.size < maxRows &&
            inbox.sumOf(File::length) < maxBytes
        ) {
            files.delete(faultFile)
        }
    }

    private fun readMiss(): Pair<CaptureMissReason, Long>? {
        if (!missFile.exists()) return null
        return try {
            val parts = String(files.read(missFile), StandardCharsets.US_ASCII).split('|')
            require(parts.size == 3 && parts[0] == SCHEMA)
            CaptureMissReason.valueOf(parts[1]) to parts[2].toLong()
        } catch (_: Exception) {
            null
        }
    }

    private fun classify(error: Exception): CaptureFaultCode = when (error) {
        is KeyInvalidatedException -> CaptureFaultCode.keyInvalidated
        is javax.crypto.AEADBadTagException,
        is IllegalArgumentException,
        is java.nio.charset.CharacterCodingException -> CaptureFaultCode.corruption
        else -> CaptureFaultCode.storage
    }

    private fun validate(record: TrustedSmsRecord) {
        require(record.id.matches(Regex("^[A-Za-z0-9_-]{43}$")))
        require(SenderRules.normalize(record.sender) == record.sender)
        require(record.segments in 1..SmsCapturePolicy.MAX_SEGMENTS)
        require(record.body.toByteArray(StandardCharsets.UTF_8).size <= SmsCapturePolicy.MAX_BYTES)
    }

    private fun encode(record: TrustedSmsRecord): ByteArray {
        val body = record.body.toByteArray(StandardCharsets.UTF_8)
        return ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(1)
                output.writeUTF(record.id)
                output.writeUTF(record.sender)
                output.writeLong(record.receivedAtMillis)
                output.writeInt(record.segments)
                output.writeInt(body.size)
                output.write(body)
            }
            bytes.toByteArray()
        }
    }

    private fun encodeDecision(record: DecisionRecord): ByteArray =
        "$SCHEMA|${record.decision.name}|${record.decidedAtMillis}".toByteArray(StandardCharsets.US_ASCII)

    private fun readDecision(id: String): DecisionRecord {
        val cleartext = inboxCrypto.decrypt("decision", id, files.read(decisionFileForTest(id)))
        val parts = String(cleartext, StandardCharsets.US_ASCII).split('|')
        require(parts.size == 3 && parts[0] == SCHEMA)
        val decision = CaptureDecision.valueOf(parts[1])
        val decidedAtMillis = parts[2].toLong()
        require(decidedAtMillis >= 0)
        return DecisionRecord(decision, decidedAtMillis)
    }

    private fun decode(payload: ByteArray): TrustedSmsRecord = DataInputStream(ByteArrayInputStream(payload)).use { input ->
        require(input.readInt() == 1)
        val id = input.readUTF()
        val sender = input.readUTF()
        val receivedAt = input.readLong()
        val segments = input.readInt()
        val bodyLength = input.readInt()
        require(bodyLength in 0..SmsCapturePolicy.MAX_BYTES)
        val body = ByteArray(bodyLength).also(input::readFully)
        require(input.available() == 0)
        TrustedSmsRecord(id, sender, receivedAt, segments, decodeUtf8Strict(body)).also(::validate)
    }

    private fun decodeUtf8Strict(bytes: ByteArray): String = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString()
}
