package com.congodeveloperclub.opencongopay.sms

import android.content.Context
import android.util.Base64
import java.io.File
import java.nio.charset.StandardCharsets

internal class PaymentOutboxVault(context: Context) {
    companion object {
        private const val ALIAS = "openpay_payment_outbox_v1"
    }

    private val legacyRoot = PaymentOutboxStorageRoots.flutterDocumentsRoot(context.filesDir)
    private val root = File(context.noBackupFilesDir, "payment_outbox_v1")
    private val keyMarker = File(root, "keystore-bound")
    private val crypto = AesGcmEnvelopeCrypto(
        AndroidKeystoreKeyAccess(ALIAS) { keyMarker.isFile },
        "payment-outbox-v1",
    )

    init {
        require(root.isDirectory || root.mkdirs())
    }

    fun storageDirectory(): String {
        PaymentOutboxDatabaseMigration.moveLegacyDatabaseIfNeeded(legacyRoot, root)

        return root.absolutePath
    }

    fun encrypt(identity: String, cleartext: String): String = try {
        validateIdentity(identity)
        val result = crypto.encrypt("outbox", identity, cleartext.toByteArray(StandardCharsets.UTF_8))
        if (!keyMarker.exists()) keyMarker.writeText("v1", StandardCharsets.US_ASCII)
        Base64.encodeToString(result, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
    } catch (error: KeyInvalidatedException) {
        throw OutboxRecoveryRequiredException(error)
    } catch (error: Exception) {
        throw OutboxStorageException(error)
    }

    fun decrypt(identity: String, ciphertext: String): String = try {
        validateIdentity(identity)
        String(
            crypto.decrypt(
                "outbox",
                identity,
                Base64.decode(ciphertext, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE),
            ),
            StandardCharsets.UTF_8,
        )
    } catch (error: KeyInvalidatedException) {
        throw OutboxRecoveryRequiredException(error)
    } catch (error: Exception) {
        throw OutboxRecoveryRequiredException(error)
    }

    private fun validateIdentity(identity: String) {
        require(identity.matches(Regex("^[a-f0-9]{64}$")))
    }

}

/**
 * V1 used Flutter's documents directory, which Android backs up. Move its
 * SQLite database (and any journal) into the no-backup directory before Dart
 * opens it for the transactional V1-to-V2 ciphertext migration.
 *
 * Sidecars move first. If interruption happens before the main file moves, a
 * restart safely resumes. Conflicting copies fail closed rather than choosing
 * one or recreating an outbox.
 */
internal object PaymentOutboxDatabaseMigration {
    private const val DATABASE_NAME = "opencongopay-outbox.db"
    private val SQLITE_SIDECARS = listOf("-journal", "-wal", "-shm")

    fun moveLegacyDatabaseIfNeeded(legacyRoot: File, encryptedRoot: File) {
        val source = File(legacyRoot, DATABASE_NAME)
        val destination = File(encryptedRoot, DATABASE_NAME)

        if (source.exists() && destination.exists()) {
            throw OutboxRecoveryRequiredException()
        }

        for (suffix in SQLITE_SIDECARS) {
            val sourceSidecar = File(legacyRoot, "$DATABASE_NAME$suffix")
            val destinationSidecar = File(encryptedRoot, "$DATABASE_NAME$suffix")
            if (!sourceSidecar.exists()) continue
            if (destinationSidecar.exists() || !sourceSidecar.renameTo(destinationSidecar)) {
                throw OutboxRecoveryRequiredException()
            }
        }

        if (source.exists() && !source.renameTo(destination)) {
            throw OutboxRecoveryRequiredException()
        }
    }
}

/** Flutter's Android documents directory is `<filesDir>/app_flutter`. */
internal object PaymentOutboxStorageRoots {
    fun flutterDocumentsRoot(filesDir: File): File = File(filesDir, "app_flutter")
}

internal class OutboxRecoveryRequiredException(cause: Throwable? = null) : Exception("outbox_recovery_required", cause)
internal class OutboxStorageException(cause: Throwable? = null) : Exception("outbox_storage_failure", cause)

internal object PaymentOutboxVaultProvider {
    @Volatile private var instance: PaymentOutboxVault? = null

    fun get(context: Context): PaymentOutboxVault = instance ?: synchronized(this) {
        instance ?: PaymentOutboxVault(context.applicationContext).also { instance = it }
    }
}
