package com.congodeveloperclub.opencongopay.sms

import java.io.File
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.AEADBadTagException
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AtomicSmsQueueTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun aadAuthenticatesVersionTypeAndIdentity() {
        val crypto = testCrypto()
        val encrypted = crypto.encrypt("inbox", "record-a", "secret".toByteArray())
        assertEquals("secret", String(crypto.decrypt("inbox", "record-a", encrypted)))
        assertThrows(AEADBadTagException::class.java) {
            crypto.decrypt("inbox", "record-b", encrypted)
        }
        assertThrows(AEADBadTagException::class.java) {
            crypto.decrypt("decision", "record-a", encrypted)
        }
        val encryptedEmpty = crypto.encrypt("rules", "trusted-senders", byteArrayOf())
        assertTrue(crypto.decrypt("rules", "trusted-senders", encryptedEmpty).isEmpty())
    }

    @Test
    fun idempotencyCapacityAndCorruptionBecomeDurableFaults() {
        val capacityRoot = temporary.newFolder("capacity")
        val queue = queue(capacityRoot, maxRows = 1, maxBytes = 8192)
        val first = record("a".repeat(43), "one")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(first))
        assertEquals(PersistResult.duplicate, queue.persistIfAbsent(first))
        assertEquals(PersistResult.faulted, queue.persistIfAbsent(record("b".repeat(43), "two")))
        assertEquals(CaptureFaultCode.capacity, queue.health().fault)
        assertTrue(File(capacityRoot, "fault.state").exists())

        val corruptionRoot = temporary.newFolder("corruption")
        val corruptionQueue = queue(corruptionRoot)
        assertEquals(PersistResult.stored, corruptionQueue.persistIfAbsent(first))
        corruptionQueue.recordFileForTest(first.id).writeBytes(byteArrayOf(1, 2, 3))
        assertThrows(SmsStorageException::class.java) { corruptionQueue.records() }
        assertEquals(CaptureFaultCode.corruption, corruptionQueue.health().fault)
        assertTrue(File(corruptionRoot, "quarantine").listFiles()!!.isNotEmpty())
    }

    @Test
    fun inboxRejectsEmbeddedIdMismatchAndMalformedUtf8() {
        listOf(
            encodedRecord("b".repeat(43), "ORANGE", byteArrayOf(65)),
            encodedRecord("a".repeat(43), "ORANGE", byteArrayOf(0xC3.toByte(), 0x28)),
        ).forEachIndexed { index, cleartext ->
            val root = temporary.newFolder("strict-record-$index")
            val crypto = testCrypto()
            val queue = AtomicSmsQueue(root, crypto, crypto)
            val id = "a".repeat(43)
            queue.recordFileForTest(id).writeBytes(crypto.encrypt("inbox", id, cleartext))
            assertThrows(SmsStorageException::class.java) { queue.records() }
            assertEquals(CaptureFaultCode.corruption, queue.health().fault)
        }
    }

    @Test
    fun decisionIsDurableBeforeDeleteAndCrashRetryIsIdempotent() {
        val files = FailFirstInboxDeleteFileOps(JvmAtomicFileOps())
        val queue = queue(files = files)
        val record = record("c".repeat(43), "review me")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(record))
        assertThrows(SmsStorageException::class.java) {
            queue.commitDecision(record.id, CaptureDecision.reviewed)
        }
        assertTrue(queue.decisionFileForTest(record.id).exists())
        assertTrue(queue.recordFileForTest(record.id).exists())
        queue.commitDecision(record.id, CaptureDecision.reviewed)
        assertFalse(queue.recordFileForTest(record.id).exists())
        assertTrue(queue.decisionFileForTest(record.id).exists())
    }

    @Test
    fun decidedDigestIsNeverCapturedAgain() {
        val queue = queue(temporary.newFolder("decided-replay"))
        val evidence = record("r".repeat(43), "reviewed once")

        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        queue.commitDecision(evidence.id, CaptureDecision.reviewed)

        assertEquals(PersistResult.decided, queue.persistIfAbsent(evidence))
        assertTrue(queue.records().isEmpty())
    }

    @Test
    fun conflictingDecisionFirstCompletesCrashRetainedTransactionThenConflicts() {
        val files = FailFirstInboxDeleteFileOps(JvmAtomicFileOps())
        val queue = queue(temporary.newFolder("decision-conflict"), files)
        val evidence = record("x".repeat(43), "conflict evidence")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        assertThrows(SmsStorageException::class.java) {
            queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        }

        assertThrows(DecisionConflictException::class.java) {
            queue.commitDecision(evidence.id, CaptureDecision.rejected)
        }
        assertFalse(queue.recordFileForTest(evidence.id).exists())
        assertTrue(queue.decisionFileForTest(evidence.id).exists())
    }

    @Test
    fun appendOnlyDecisionJournalRetainsMoreThanOneThousandAcrossTime() {
        var now = 2_000_000_000_000L
        val queue = queue(
            root = temporary.newFolder("decision-retention"),
            nowMillis = { now },
        )
        repeat(1001) { index ->
            val id = index.toString().padStart(43, '0')
            val evidence = record(id, "evidence-$index")
            assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
            queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        assertEquals(1001, queue.decisionCountForTest())

        now += TimeUnit.DAYS.toMillis(32)
        assertEquals(1001, queue.decisionCountForTest())
        assertEquals(PersistResult.decided, queue.persistIfAbsent(record("0".repeat(43), "evidence-0")))
    }

    @Test
    fun decisionExportUsesBoundedEncryptedPagesAndTruthfulCursor() {
        val files = CountingReadFileOps(JvmAtomicFileOps())
        val queue = queue(temporary.newFolder("decision-pages"), files)
        repeat(130) { index ->
            val evidence = record(index.toString().padStart(43, '0'), "evidence-$index")
            assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
            queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        files.reads.set(0)

        val first = queue.exportDecisions(10, null)
        assertEquals(10, first.records.size)
        assertTrue(first.truncated)
        assertTrue(first.nextCursor != null)
        assertTrue("export read ${files.reads.get()} files", files.reads.get() <= 12)

        val second = queue.exportDecisions(100, first.nextCursor)
        assertEquals(100, second.records.size)
        assertTrue(second.truncated)
        val final = queue.exportDecisions(100, second.nextCursor)
        assertEquals(20, final.records.size)
        assertFalse(final.truncated)
        assertEquals(null, final.nextCursor)
        assertEquals(130, queue.decisionStatus().count)
    }

    @Test
    fun corruptDecisionTombstoneIsQuarantinedAndFaultsExport() {
        val root = temporary.newFolder("decision-export-corrupt")
        val queue = queue(root)
        val evidence = record("q".repeat(43), "corrupt tombstone")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        queue.decisionFileForTest(evidence.id).writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) { queue.exportDecisions(100, null) }
        assertEquals(CaptureFaultCode.corruption, queue.health().fault)
        assertFalse(queue.decisionFileForTest(evidence.id).exists())
        assertTrue(File(root, "quarantine").listFiles()!!.isNotEmpty())
    }

    @Test
    fun `export durably marks recovery before quarantining corrupt tombstone`() {
        val root = temporary.newFolder("decision-export-marker-order")
        val files = MarkerOrderFileOps(JvmAtomicFileOps())
        val queue = queue(root, files)
        val evidence = record("x".repeat(43), "export marker order")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        files.events.clear()
        queue.decisionFileForTest(evidence.id).writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) { queue.exportDecisions(10, null) }
        assertEquals(listOf("marker-durable", "quarantine"), files.events)
    }

    @Test
    fun `existing tombstone corruption makes decision commit durable typed recovery`() {
        val root = temporary.newFolder("decision-existing-corrupt")
        val queue = queue(root)
        val evidence = record("e".repeat(43), "existing corrupt tombstone")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        queue.decisionFileForTest(evidence.id).writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) {
            queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        assertTrue(File(root, "journal-recovery-required.state").exists())
        assertThrows(RecoveryRequiredException::class.java) { queue(root).decisionStatus() }
    }

    @Test
    fun `pending recovery target corruption is durable typed recovery across restart`() {
        val root = temporary.newFolder("pending-target-corrupt")
        val files = FailFirstInboxDeleteFileOps(JvmAtomicFileOps())
        val queue = queue(root, files)
        val evidence = record("g".repeat(43), "pending target corrupt")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        assertThrows(SmsStorageException::class.java) {
            queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        assertTrue(File(root, "decision-pending.enc").exists())
        queue.decisionFileForTest(evidence.id).writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) {
            queue(root).commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        assertTrue(File(root, "journal-recovery-required.state").exists())
        assertThrows(RecoveryRequiredException::class.java) { queue(root).decisionStatus() }
    }

    @Test
    fun `decision commit first corrupt pending decode is typed recovery across restart`() {
        val root = temporary.newFolder("commit-corrupt-pending")
        val files = FailFirstInboxDeleteFileOps(JvmAtomicFileOps())
        val queue = queue(root, files)
        val evidence = record("h".repeat(43), "commit corrupt pending")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        assertThrows(SmsStorageException::class.java) {
            queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        File(root, "decision-pending.enc").writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) {
            queue(root).commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        assertTrue(File(root, "journal-recovery-required.state").exists())
        assertThrows(RecoveryRequiredException::class.java) { queue(root).decisionStatus() }
    }

    @Test
    fun `decision commit first corrupt manifest is typed recovery across restart`() {
        val root = temporary.newFolder("commit-corrupt-manifest")
        val queue = queue(root)
        val first = record("j".repeat(43), "manifest seed")
        val second = record("k".repeat(43), "manifest first detection")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(first))
        queue.commitDecision(first.id, CaptureDecision.reviewed)
        assertEquals(PersistResult.stored, queue.persistIfAbsent(second))
        File(root, "decision-manifest.enc").writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) {
            queue.commitDecision(second.id, CaptureDecision.reviewed)
        }
        assertTrue(File(root, "journal-recovery-required.state").exists())
        assertThrows(RecoveryRequiredException::class.java) { queue(root).decisionStatus() }
    }

    @Test
    fun `decision commit first corrupt index is typed recovery across restart`() {
        val root = temporary.newFolder("commit-corrupt-index")
        val queue = queue(root)
        val first = record("l".repeat(43), "index seed")
        val second = record("m".repeat(43), "index first detection")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(first))
        queue.commitDecision(first.id, CaptureDecision.reviewed)
        assertEquals(PersistResult.stored, queue.persistIfAbsent(second))
        queue.decisionIndexFileForTest(0).writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) {
            queue.commitDecision(second.id, CaptureDecision.reviewed)
        }
        assertTrue(File(root, "journal-recovery-required.state").exists())
        assertThrows(RecoveryRequiredException::class.java) { queue(root).decisionStatus() }
    }

    @Test
    fun emptyTrustedAllowlistFailsClosedAndCanBeListedRevokedAndCleared() {
        val queue = queue(temporary.newFolder("trusted-rules"))
        queue.replaceTrustedSenders(emptyList())
        assertEquals(emptyList<String>(), queue.trustedSenders())
        assertFalse(queue.isTrustedSender("ORANGE"))
        queue.replaceTrustedSenders(listOf("ORANGE", "+243990001111"))
        assertEquals(listOf("+243990001111", "ORANGE"), queue.trustedSenders())
        queue.revokeTrustedSender("ORANGE")
        assertEquals(listOf("+243990001111"), queue.trustedSenders())
        queue.clearTrustedSenders()
        assertEquals(emptyList<String>(), queue.trustedSenders())
        assertFalse(queue.isTrustedSender("+243990001111"))
    }

    @Test
    fun `atomic trusted sender add revoke and clear are idempotent and authoritative`() {
        val queue = queue(temporary.newFolder("trusted-rule-mutations"))
        assertEquals(listOf("ORANGE"), queue.addTrustedSender("ORANGE"))
        assertEquals(listOf("ORANGE"), queue.addTrustedSender("ORANGE"))
        assertEquals(emptyList<String>(), queue.revokeTrustedSender("ORANGE"))
        assertEquals(emptyList<String>(), queue.revokeTrustedSender("ORANGE"))
        assertEquals(emptyList<String>(), queue.clearTrustedSenders())
    }

    @Test
    fun appendOnlyDecisionJournalNeverBlocksLaterCapture() {
        val queue = queue(
            root = temporary.newFolder("decision-capacity"),
            maxRows = 2,
        )
        val first = record("4".repeat(43), "first")
        val second = record("5".repeat(43), "second")
        val next = record("6".repeat(43), "next")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(first))
        assertEquals(PersistResult.stored, queue.persistIfAbsent(second))
        queue.commitDecision(first.id, CaptureDecision.reviewed)
        queue.commitDecision(second.id, CaptureDecision.rejected)

        assertTrue(queue.records().isEmpty())
        assertEquals(PersistResult.decided, queue.persistIfAbsent(second))
        assertEquals(null, queue.health().fault)
        assertEquals(PersistResult.stored, queue.persistIfAbsent(next))
    }

    @Test
    fun nextCaptureProbesAndRecoversTransientStorageFaultWithEmptyInbox() {
        val files = FailFirstInboxWriteFileOps(JvmAtomicFileOps())
        val queue = queue(temporary.newFolder("storage-probe"), files)
        val evidence = record("7".repeat(43), "retry after storage fault")

        assertEquals(PersistResult.faulted, queue.persistIfAbsent(evidence))
        assertEquals(CaptureFaultCode.storage, queue.health().fault)
        assertTrue(queue.records().isEmpty())

        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        assertEquals(null, queue.health().fault)
        assertEquals(listOf(evidence), queue.records())
    }

    @Test
    fun `pending decision survives restart until decided source is deleted`() {
        val root = temporary.newFolder("pending-source-delete")
        val files = FailFirstInboxDeleteFileOps(JvmAtomicFileOps())
        val first = queue(root, files)
        val evidence = record("p".repeat(43), "pending deletion")
        assertEquals(PersistResult.stored, first.persistIfAbsent(evidence))
        assertThrows(SmsStorageException::class.java) {
            first.commitDecision(evidence.id, CaptureDecision.reviewed)
        }
        assertTrue(File(root, "decision-pending.enc").exists())
        assertTrue(first.recordFileForTest(evidence.id).exists())

        val restarted = queue(root, files)
        assertEquals(1, restarted.decisionStatus().count)
        assertFalse(restarted.recordFileForTest(evidence.id).exists())
        assertFalse(File(root, "decision-pending.enc").exists())
        assertEquals(PersistResult.decided, restarted.persistIfAbsent(evidence))
    }

    @Test
    fun `decision transaction recovers every durable phase after restart`() {
        val id = "t".repeat(43)
        val phases = listOf(
            FileFailure("decision-pending.enc", FileOperation.write),
            FileFailure("decisions/$id.enc", FileOperation.write),
            FileFailure("decision-index/0000000000.enc", FileOperation.write),
            FileFailure("decision-manifest.enc", FileOperation.write),
            FileFailure("inbox/$id.enc", FileOperation.delete),
            FileFailure("decision-pending.enc", FileOperation.delete),
        )
        phases.forEachIndexed { index, phase ->
            val root = temporary.newFolder("decision-phase-$index")
            val files = FailOncePathFileOps(root, JvmAtomicFileOps(), phase)
            val first = queue(root, files)
            val evidence = record(id, "phase-$index")
            assertEquals(PersistResult.stored, first.persistIfAbsent(evidence))
            files.arm()
            assertThrows(SmsStorageException::class.java) {
                first.commitDecision(id, CaptureDecision.reviewed)
            }

            val restarted = queue(root, files)
            restarted.commitDecision(id, CaptureDecision.reviewed)
            assertFalse(restarted.recordFileForTest(id).exists())
            assertFalse(File(root, "decision-pending.enc").exists())
            assertTrue(restarted.decisionFileForTest(id).exists())
            assertEquals(1, restarted.decisionStatus().count)
            assertEquals(PersistResult.decided, restarted.persistIfAbsent(evidence))
        }
    }

    @Test
    fun `invalid cursor is typed and never poisons durable health`() {
        val queue = queue(temporary.newFolder("invalid-cursor"))
        val evidence = record("u".repeat(43), "cursor")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        queue.commitDecision(evidence.id, CaptureDecision.reviewed)

        assertThrows(InvalidDecisionCursorException::class.java) {
            queue.exportDecisions(10, "v3:0:1")
        }
        assertThrows(InvalidDecisionCursorException::class.java) {
            queue.exportDecisions(10, "v3:9:0")
        }
        assertEquals(null, queue.health().fault)
        val page = queue.exportDecisions(1, null)
        assertEquals(1, page.records.size)
        assertFalse(page.truncated)
    }

    @Test
    fun `legacy v2 ciphertext blocks v3 without touching legacy data`() {
        val legacy = temporary.newFolder("trusted_sms_v2")
        val ciphertext = File(legacy, "decision-manifest.enc").apply {
            writeBytes(byteArrayOf(1, 2, 3))
        }
        assertThrows(LegacySmsMigrationRequiredException::class.java) {
            LegacySmsStorageGuard.requireNoCiphertext(legacy)
        }
        assertTrue(ciphertext.exists())
        assertTrue(ciphertext.readBytes().contentEquals(byteArrayOf(1, 2, 3)))
    }

    @Test
    fun `key loss inventory includes journal controls indexes and quarantine`() {
        val root = temporary.newFolder("ciphertext-inventory")
        val candidates = listOf(
            File(root, "rules.enc"),
            File(root, "inbox/record.enc"),
            File(root, "decisions/tombstone.enc"),
            File(root, "decision-pending.enc"),
            File(root, "decision-manifest.enc"),
            File(root, "decision-index/0000000000.enc"),
            File(root, "quarantine/record.enc.1.bad"),
        )
        for (candidate in candidates) {
            root.deleteRecursively()
            root.mkdirs()
            candidate.parentFile!!.mkdirs()
            candidate.writeBytes(byteArrayOf(1))
            assertTrue("missed ${candidate.name}", SmsCiphertextInventory.exists(root))
        }
    }

    @Test
    fun `rules and inbox first use do not invalidate the other domain key`() {
        listOf(true, false).forEachIndexed { index, rulesFirst ->
            val root = temporary.newFolder("domain-first-use-$index")
            File(root, "inbox").mkdirs()
            val rulesAccess = InventoryBackedKeyAccess(root, SmsCiphertextDomain.rules)
            val inboxAccess = InventoryBackedKeyAccess(root, SmsCiphertextDomain.inbox)
            val rulesCrypto = AesGcmEnvelopeCrypto(rulesAccess, "rules-v3")
            val inboxCrypto = AesGcmEnvelopeCrypto(inboxAccess, "inbox-v3")
            val writeRules = {
                File(root, "rules.enc").writeBytes(
                    rulesCrypto.encrypt("rules", "trusted-senders", "ORANGE".toByteArray()),
                )
            }
            val writeInbox = {
                File(root, "inbox/record.enc").writeBytes(
                    inboxCrypto.encrypt("inbox", "record", "evidence".toByteArray()),
                )
            }
            if (rulesFirst) {
                writeRules()
                writeInbox()
            } else {
                writeInbox()
                writeRules()
            }
            assertTrue(SmsCiphertextInventory.exists(root, SmsCiphertextDomain.rules))
            assertTrue(SmsCiphertextInventory.exists(root, SmsCiphertextDomain.inbox))
        }
    }

    @Test
    fun `domain key loss fails closed only for ciphertext in that domain`() {
        val root = temporary.newFolder("domain-key-loss")
        File(root, "inbox").mkdirs()
        val rules = InventoryBackedKeyAccess(root, SmsCiphertextDomain.rules)
        val inbox = InventoryBackedKeyAccess(root, SmsCiphertextDomain.inbox)
        File(root, "rules.enc").writeBytes(
            AesGcmEnvelopeCrypto(rules, "rules-v3")
                .encrypt("rules", "trusted-senders", "ORANGE".toByteArray()),
        )
        inbox.keyForEncrypt()
        rules.loseKey()
        assertThrows(KeyInvalidatedException::class.java) { rules.keyForEncrypt() }
        assertTrue(inbox.keyForEncrypt().encoded.isNotEmpty())
    }

    @Test
    fun `quarantine inventory is tagged and isolated by crypto domain`() {
        val root = temporary.newFolder("domain-quarantine")
        val quarantine = File(root, "quarantine")
        val files = JvmAtomicFileOps()
        val rulesFile = File(root, "rules.enc").apply { writeBytes(byteArrayOf(1)) }
        assertTrue(files.quarantine(rulesFile, quarantine, SmsCiphertextDomain.rules))
        assertTrue(SmsCiphertextInventory.exists(root, SmsCiphertextDomain.rules))
        assertFalse(SmsCiphertextInventory.exists(root, SmsCiphertextDomain.inbox))

        val inboxFile = File(root, "inbox/record.enc").apply {
            parentFile!!.mkdirs()
            writeBytes(byteArrayOf(1))
        }
        assertTrue(files.quarantine(inboxFile, quarantine, SmsCiphertextDomain.inbox))
        assertTrue(SmsCiphertextInventory.exists(root, SmsCiphertextDomain.inbox))
    }

    @Test
    fun `corrupt manifest recovery survives repeated status export and restart`() {
        val root = temporary.newFolder("journal-controls-corrupt")
        val queue = queue(root)
        File(root, "decision-manifest.enc").writeBytes(byteArrayOf(1, 2, 3))
        assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
        assertTrue(File(root, "journal-recovery-required.state").exists())
        assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
        assertThrows(RecoveryRequiredException::class.java) { queue.exportDecisions(10, null) }
        assertThrows(RecoveryRequiredException::class.java) {
            queue.commitDecision("c".repeat(43), CaptureDecision.reviewed)
        }
        assertThrows(RecoveryRequiredException::class.java) { queue(root).decisionStatus() }
        assertEquals(CaptureFaultCode.corruption, queue.health().fault)
        assertFalse(File(root, "decision-manifest.enc").exists())
        assertTrue(File(root, "quarantine").listFiles()!!.isNotEmpty())
    }

    @Test
    fun `journal marker durable write completes before control quarantine`() {
        val root = temporary.newFolder("journal-marker-order")
        val files = MarkerOrderFileOps(JvmAtomicFileOps())
        val queue = queue(root, files)
        File(root, "decision-manifest.enc").writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
        assertEquals(listOf("marker-durable", "quarantine"), files.events)
    }

    @Test
    fun `missing manifest is recovery when any journal ciphertext remains`() {
        val journalPaths = listOf(
            "decisions/${"m".repeat(43)}.enc",
            "decision-index/0000000000.enc",
            "quarantine/inbox--decision-manifest.enc.1.bad",
        )
        journalPaths.forEachIndexed { index, relativePath ->
            val root = temporary.newFolder("missing-manifest-journal-$index")
            val queue = queue(root)
            File(root, relativePath).apply {
                parentFile!!.mkdirs()
                writeBytes(byteArrayOf(1, 2, 3))
            }

            assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
            assertTrue(File(root, "journal-recovery-required.state").exists())
        }
    }

    @Test
    fun `missing manifest is an empty journal only when no journal state exists`() {
        val root = temporary.newFolder("missing-manifest-clean")
        val queue = queue(root)

        assertEquals(DecisionJournalStatus(0, 0), queue.decisionStatus())
        assertEquals(DecisionExportPage(emptyList(), null, false), queue.exportDecisions(10, null))
        assertFalse(File(root, "journal-recovery-required.state").exists())
    }

    @Test
    fun `corrupt pending with an old manifest stays recovery required after restart`() {
        val root = temporary.newFolder("corrupt-pending-old-manifest")
        val queue = queue(root)
        val evidence = record("o".repeat(43), "old manifest")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
        queue.commitDecision(evidence.id, CaptureDecision.reviewed)
        assertTrue(File(root, "decision-manifest.enc").exists())
        File(root, "decision-pending.enc").writeBytes(byteArrayOf(1, 2, 3))

        assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
        assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
        assertThrows(RecoveryRequiredException::class.java) { queue(root).exportDecisions(10, null) }
        assertTrue(File(root, "journal-recovery-required.state").exists())
    }

    @Test
    fun `journal recovery stays typed when durable fault metadata write also fails`() {
        val root = temporary.newFolder("journal-fault-write-fails")
        val files = FailOncePathFileOps(
            root,
            JvmAtomicFileOps(),
            FileFailure("fault.state", FileOperation.write),
        )
        val queue = queue(root, files)
        File(root, "decision-manifest.enc").writeBytes(byteArrayOf(1, 2, 3))
        files.arm()

        assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
        assertEquals(null, queue.health().fault)
        assertTrue(File(root, "journal-recovery-required.state").exists())
        assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
        assertThrows(RecoveryRequiredException::class.java) { queue(root).exportDecisions(10, null) }
        assertTrue(File(root, "quarantine").listFiles()!!.isNotEmpty())
    }

    @Test
    fun `corrupt pending and index controls quarantine and preserve readable health`() {
        listOf("pending", "index").forEach { control ->
            val root = temporary.newFolder("journal-$control-corrupt")
            val queue = queue(root)
            val evidence = record((if (control == "pending") "n" else "i").repeat(43), control)
            assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
            if (control == "pending") {
                File(root, "decision-pending.enc").writeBytes(byteArrayOf(1, 2, 3))
                assertThrows(RecoveryRequiredException::class.java) { queue.decisionStatus() }
            } else {
                queue.commitDecision(evidence.id, CaptureDecision.reviewed)
                queue.decisionIndexFileForTest(0).writeBytes(byteArrayOf(1, 2, 3))
                assertThrows(RecoveryRequiredException::class.java) { queue.exportDecisions(10, null) }
            }
            assertEquals(CaptureFaultCode.corruption, queue.health().fault)
            assertTrue(File(root, "quarantine").listFiles()!!.isNotEmpty())
        }
    }

    @Test
    fun `segmented decision pages make strict progress without repeats`() {
        val queue = queue(temporary.newFolder("decision-page-progress"))
        repeat(70) { index ->
            val id = index.toString().padStart(43, '0')
            val evidence = record(id, "page-$index")
            assertEquals(PersistResult.stored, queue.persistIfAbsent(evidence))
            queue.commitDecision(id, CaptureDecision.reviewed)
        }
        val seen = mutableSetOf<String>()
        var cursor: String? = null
        do {
            val previous = cursor
            val page = queue.exportDecisions(7, cursor)
            assertTrue(page.records.isNotEmpty())
            assertTrue(page.records.all { seen.add(it.id) })
            cursor = page.nextCursor
            if (cursor != null) assertTrue(cursor != previous)
            assertEquals(cursor != null, page.truncated)
        } while (cursor != null)
        assertEquals(70, seen.size)
        assertEquals(null, queue.health().fault)
    }

    @Test
    fun storageProbeNeverClearsPermanentFaults() {
        listOf(
            CaptureFaultCode.capacity,
            CaptureFaultCode.corruption,
            CaptureFaultCode.keyInvalidated,
        ).forEachIndexed { index, fault ->
            val queue = queue(temporary.newFolder("permanent-probe-$index"))
            queue.recordFault(fault)
            assertFalse(queue.probeStorage())
            assertEquals(fault, queue.health().fault)
        }
    }

    @Test
    fun recoveryHealthNeverPublishesJournalCounts() {
        listOf(
            CaptureFaultCode.corruption,
            CaptureFaultCode.keyInvalidated,
        ).forEach { fault ->
            val projected = SmsHealthProjection.forFlutter(
                CaptureHealth(
                    fault = fault,
                    occurredAtMillis = null,
                    missed = null,
                    missedAtMillis = null,
                ),
                DecisionJournalStatus(count = 0, encryptedBytes = 0),
                journalRecoveryRequired = false,
            )

            assertEquals(true, projected["recovery_required"])
            assertEquals(null, projected["decision_count"])
            assertEquals(null, projected["decision_encrypted_bytes"])
        }
    }

    @Test
    fun missedCaptureSignalNeverBlocksLaterCapture() {
        val queue = queue(temporary.newFolder("miss-signal"))
        queue.recordMissSignal(CaptureMissReason.overload)
        assertEquals(CaptureMissReason.overload, queue.health().missed)
        assertEquals(null, queue.health().fault)
        assertEquals(
            PersistResult.stored,
            queue.persistIfAbsent(record("8".repeat(43), "after overload")),
        )
    }

    @Test
    fun atomicRenameSyncsParentDirectoryAfterTargetExists() {
        val root = temporary.newFolder("directory-sync")
        val target = File(root, "record.enc")
        val observed = mutableListOf<String>()
        val files = JvmAtomicFileOps(DirectorySync { directory ->
            assertEquals(root, directory)
            assertTrue(target.exists())
            observed.add("synced")
        })
        files.writeAtomic(target, byteArrayOf(1))
        assertEquals(listOf("synced"), observed)
    }

    @Test
    fun queueCreationSyncsRootAfterCreatingEveryStorageDirectory() {
        val parent = temporary.newFolder("directory-root-parent")
        val root = File(parent, "vault")
        val synced = CopyOnWriteArrayList<File>()
        val files = JvmAtomicFileOps(DirectorySync(synced::add))

        queue(root, files)

        assertTrue(root.isDirectory)
        assertTrue(synced.contains(parent))
        assertTrue(synced.count { it == root } >= 4)
    }

    @Test
    fun missingKeyWithCiphertextFaultsAndRequiresExplicitRecovery() {
        val keyAccess = InvalidatedKeyAccess()
        val queue = AtomicSmsQueue(
            temporary.root,
            AesGcmEnvelopeCrypto(keyAccess, "rules"),
            AesGcmEnvelopeCrypto(keyAccess, "inbox"),
        )
        val record = record("d".repeat(43), "secret")
        assertEquals(PersistResult.stored, queue.persistIfAbsent(record))
        keyAccess.invalidated = true
        assertThrows(SmsStorageException::class.java) { queue.records() }
        assertEquals(CaptureFaultCode.keyInvalidated, queue.health().fault)
        assertFalse(queue.recordFileForTest(record.id).exists())
        assertTrue(File(temporary.root, "quarantine").listFiles()!!.isNotEmpty())
        assertEquals(CaptureFaultCode.keyInvalidated, queue.health().fault)
    }

    @Test
    fun boundedDispatcherNeverRunsCaptureOnCallerAndReportsOverloadAndExpiry() {
        val now = AtomicLong(0)
        val firstStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondExpired = CountDownLatch(1)
        val callerThread = Thread.currentThread()
        val executionThreads = CopyOnWriteArrayList<Thread>()
        val missed = CopyOnWriteArrayList<CaptureMissReason>()
        val dispatcher = BoundedCaptureDispatcher(
            threads = 1,
            queueCapacity = 1,
            maxQueueDelayNanos = 10,
            nowNanos = now::get,
        )
        val expired = {
            missed.add(CaptureMissReason.expired)
            secondExpired.countDown()
        }

        assertTrue(dispatcher.dispatch(expired) {
            executionThreads.add(Thread.currentThread())
            firstStarted.countDown()
            releaseFirst.await(5, TimeUnit.SECONDS)
        } != null)
        assertTrue(firstStarted.await(5, TimeUnit.SECONDS))
        assertTrue(dispatcher.dispatch(expired) { executionThreads.add(Thread.currentThread()) } != null)
        assertEquals(null, dispatcher.dispatch(expired) { executionThreads.add(Thread.currentThread()) })

        now.set(11)
        releaseFirst.countDown()
        assertTrue(secondExpired.await(5, TimeUnit.SECONDS))
        assertTrue(missed.contains(CaptureMissReason.expired))
        assertTrue(executionThreads.none { it == callerThread })
        dispatcher.closeForTest()
    }

    @Test
    fun concurrentBurstPersistsEveryUniqueRecordExactlyOnce() {
        val queue = queue(temporary.newFolder("burst"))
        val dispatcher = BoundedCaptureDispatcher(threads = 4, queueCapacity = 64)
        val complete = CountDownLatch(32)
        val stored = AtomicInteger()
        repeat(32) { index ->
            dispatcher.dispatch(onExpired = {}) {
                val id = index.toString().padStart(43, '0')
                if (queue.persistIfAbsent(record(id, "body-$index")) == PersistResult.stored) {
                    stored.incrementAndGet()
                }
                complete.countDown()
            }
        }
        assertTrue(complete.await(10, TimeUnit.SECONDS))
        assertEquals(32, stored.get())
        assertEquals(32, queue.records().size)
        assertEquals(null, queue.health().fault)
        dispatcher.closeForTest()
    }

    private fun queue(
        root: File = temporary.root,
        files: AtomicFileOps = JvmAtomicFileOps(),
        maxRows: Int = 500,
        maxBytes: Long = 2L * 1024L * 1024L,
        nowMillis: () -> Long = System::currentTimeMillis,
    ): AtomicSmsQueue {
        val crypto = testCrypto()
        return AtomicSmsQueue(root, crypto, crypto, files, maxRows, maxBytes, nowMillis)
    }

    private fun testCrypto(): AesGcmEnvelopeCrypto = AesGcmEnvelopeCrypto(
        FixedKeyAccess(SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")),
        "test",
    )

    private fun record(id: String, body: String) = TrustedSmsRecord(
        id = id,
        sender = "ORANGE",
        receivedAtMillis = 2_000_000_000_000L,
        segments = 1,
        body = body,
    )

    private fun encodedRecord(id: String, sender: String, body: ByteArray): ByteArray =
        ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(1)
                output.writeUTF(id)
                output.writeUTF(sender)
                output.writeLong(2_000_000_000_000L)
                output.writeInt(1)
                output.writeInt(body.size)
                output.write(body)
            }
            bytes.toByteArray()
        }
}

private class FixedKeyAccess(private val key: SecretKey) : SecretKeyAccess {
    override fun keyForEncrypt(): SecretKey = key
    override fun keyForDecrypt(): SecretKey = key
}

private class InvalidatedKeyAccess : SecretKeyAccess {
    private val key = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")
    var invalidated = false
    override fun keyForEncrypt(): SecretKey = if (invalidated) throw KeyInvalidatedException() else key
    override fun keyForDecrypt(): SecretKey = if (invalidated) throw KeyInvalidatedException() else key
}

private class InventoryBackedKeyAccess(
    private val root: File,
    private val domain: SmsCiphertextDomain,
) : SecretKeyAccess {
    private var key: SecretKey? = null

    override fun keyForEncrypt(): SecretKey {
        key?.let { return it }
        if (SmsCiphertextInventory.exists(root, domain)) throw KeyInvalidatedException()
        return SecretKeySpec(ByteArray(32) { (it + domain.ordinal + 1).toByte() }, "AES").also {
            key = it
        }
    }

    override fun keyForDecrypt(): SecretKey = key ?: throw KeyInvalidatedException()

    fun loseKey() {
        key = null
    }
}

private class FailFirstInboxDeleteFileOps(private val delegate: AtomicFileOps) : AtomicFileOps by delegate {
    private var failed = false
    override fun delete(file: File): Boolean {
        if (!failed && file.parentFile?.name == "inbox") {
            failed = true
            return false
        }
        return delegate.delete(file)
    }
}

private class FailFirstInboxWriteFileOps(private val delegate: AtomicFileOps) : AtomicFileOps by delegate {
    private var failed = false
    override fun writeAtomic(file: File, bytes: ByteArray) {
        if (!failed && file.parentFile?.name == "inbox") {
            failed = true
            throw IllegalStateException("simulated_storage_failure")
        }
        delegate.writeAtomic(file, bytes)
    }
}

private class MarkerOrderFileOps(private val delegate: AtomicFileOps) : AtomicFileOps by delegate {
    val events = mutableListOf<String>()

    override fun writeAtomic(file: File, bytes: ByteArray) {
        delegate.writeAtomic(file, bytes)
        if (file.name == "journal-recovery-required.state") events.add("marker-durable")
    }

    override fun quarantine(file: File, directory: File, domain: SmsCiphertextDomain): Boolean {
        events.add("quarantine")
        return delegate.quarantine(file, directory, domain)
    }
}

private enum class FileOperation { write, delete }

private data class FileFailure(val relativePath: String, val operation: FileOperation)

private class FailOncePathFileOps(
    private val root: File,
    private val delegate: AtomicFileOps,
    private val failure: FileFailure,
) : AtomicFileOps by delegate {
    private var armed = false
    private var failed = false

    fun arm() {
        armed = true
    }

    override fun writeAtomic(file: File, bytes: ByteArray) {
        if (shouldFail(file, FileOperation.write)) throw IllegalStateException("injected_write_failure")
        delegate.writeAtomic(file, bytes)
    }

    override fun delete(file: File): Boolean {
        if (shouldFail(file, FileOperation.delete)) return false
        return delegate.delete(file)
    }

    private fun shouldFail(file: File, operation: FileOperation): Boolean {
        if (!armed || failed || failure.operation != operation) return false
        val relative = file.relativeTo(root).invariantSeparatorsPath
        if (relative != failure.relativePath) return false
        failed = true
        return true
    }
}

private class CountingReadFileOps(private val delegate: AtomicFileOps) : AtomicFileOps by delegate {
    val reads = AtomicInteger(0)
    override fun read(file: File): ByteArray {
        reads.incrementAndGet()
        return delegate.read(file)
    }
}
