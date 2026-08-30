package com.congodeveloperclub.opencongopay.sms

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PaymentOutboxDatabaseMigrationTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun `moves legacy database and sqlite sidecars into no-backup root`() {
        val legacyRoot = temporary.newFolder("legacy")
        val encryptedRoot = temporary.newFolder("no-backup")
        database(legacyRoot).writeText("plaintext-v1")
        sidecar(legacyRoot, "-wal").writeText("plaintext-wal")

        PaymentOutboxDatabaseMigration.moveLegacyDatabaseIfNeeded(legacyRoot, encryptedRoot)

        assertFalse(database(legacyRoot).exists())
        assertFalse(sidecar(legacyRoot, "-wal").exists())
        assertTrue(database(encryptedRoot).isFile)
        assertTrue(sidecar(encryptedRoot, "-wal").isFile)
    }

    @Test
    fun `uses Flutter app_flutter documents directory as the V1 source`() {
        val filesDir = temporary.newFolder("files")

        val legacyRoot = PaymentOutboxStorageRoots.flutterDocumentsRoot(filesDir)

        assertTrue(legacyRoot.path.endsWith("files${File.separator}app_flutter"))
    }

    @Test
    fun `restart resumes a migration interrupted before the main database move`() {
        val legacyRoot = temporary.newFolder("legacy")
        val encryptedRoot = temporary.newFolder("no-backup")
        database(legacyRoot).writeText("plaintext-v1")
        sidecar(encryptedRoot, "-wal").writeText("already-moved-wal")

        PaymentOutboxDatabaseMigration.moveLegacyDatabaseIfNeeded(legacyRoot, encryptedRoot)

        assertFalse(database(legacyRoot).exists())
        assertTrue(database(encryptedRoot).isFile)
        assertTrue(sidecar(encryptedRoot, "-wal").isFile)
    }

    @Test
    fun `conflicting legacy and encrypted databases require recovery`() {
        val legacyRoot = temporary.newFolder("legacy")
        val encryptedRoot = temporary.newFolder("no-backup")
        database(legacyRoot).writeText("legacy")
        database(encryptedRoot).writeText("encrypted")

        assertThrows(OutboxRecoveryRequiredException::class.java) {
            PaymentOutboxDatabaseMigration.moveLegacyDatabaseIfNeeded(legacyRoot, encryptedRoot)
        }
    }

    private fun database(root: File): File = File(root, "opencongopay-outbox.db")

    private fun sidecar(root: File, suffix: String): File = File(root, "opencongopay-outbox.db$suffix")
}
