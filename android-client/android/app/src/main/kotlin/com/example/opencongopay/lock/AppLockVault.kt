package com.congodeveloperclub.opencongopay.lock

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64 as JvmBase64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class AppLockRecoveryRequiredException : Exception()

internal data class AppLockVerifierRecord(
    val version: Int,
    val algorithm: String,
    val memoryKib: Int,
    val iterations: Int,
    val parallelism: Int,
    val salt: String,
    val verifier: String,
    val failures: Int,
    val nextAttemptMillis: Long,
)

internal object AppLockVerifierFormat {
    const val VERSION = 1
    const val MEMORY_KIB = 64 * 1024
    const val ITERATIONS = 3
    const val PARALLELISM = 1
    const val SALT_BYTES = 16
    const val VERIFIER_BYTES = 32
    const val MAX_FAILURES = 10

    fun validPin(pin: String): Boolean =
        pin.length == 6 && pin.all { character -> character in '0'..'9' }

    fun validate(record: AppLockVerifierRecord) {
        if (record.version != VERSION ||
            record.algorithm != "argon2id" ||
            record.memoryKib != MEMORY_KIB ||
            record.iterations != ITERATIONS ||
            record.parallelism != PARALLELISM ||
            decode(record.salt).size != SALT_BYTES ||
            decode(record.verifier).size != VERIFIER_BYTES ||
            record.failures !in 0..MAX_FAILURES ||
            record.nextAttemptMillis < 0L
        ) throw AppLockRecoveryRequiredException()
    }

    private fun decode(value: String): ByteArray = try {
        JvmBase64.getDecoder().decode(value)
    } catch (_: IllegalArgumentException) {
        throw AppLockRecoveryRequiredException()
    }
}

/** Android JSON adapter; format policy above remains ordinary JVM Kotlin. */
internal object AppLockVerifierJson {
    fun validate(json: JSONObject) {
        try {
            if (json.length() != 9) throw AppLockRecoveryRequiredException()
            AppLockVerifierFormat.validate(
                AppLockVerifierRecord(
                    version = json.optInt("version", -1),
                    algorithm = json.optString("algorithm"),
                    memoryKib = json.optInt("memory_kib", -1),
                    iterations = json.optInt("iterations", -1),
                    parallelism = json.optInt("parallelism", -1),
                    salt = json.optString("salt"),
                    verifier = json.optString("verifier"),
                    failures = json.optInt("failures", -1),
                    nextAttemptMillis = json.optLong("next_attempt_ms", -1L),
                ),
            )
        } catch (_: AppLockRecoveryRequiredException) {
            throw AppLockRecoveryRequiredException()
        } catch (_: Exception) {
            throw AppLockRecoveryRequiredException()
        }
    }
}

/**
 * Android-only verifier storage. The Keystore encrypts a versioned Argon2id
 * verifier record; the PIN is never retained after derivation.
 *
 * JVM tests can prove format and failure handling only. They cannot prove
 * hardware-backed Keystore, key invalidation, or device coercion resistance.
 */
internal class AppLockVault(context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun status(): String = when {
        preferences.contains(RECORD) -> {
            readRecord()
            "ready"
        }
        else -> "enrollment_required"
    }

    fun enroll(pin: String): String {
        if (!AppLockVerifierFormat.validPin(pin)) return "invalid"
        if (preferences.contains(RECORD)) {
            readRecord()
            return "ready"
        }
        val salt = ByteArray(AppLockVerifierFormat.SALT_BYTES).also(SecureRandom()::nextBytes)
        val verifier = derive(pin, salt)
        try {
            writeRecord(
                JSONObject()
                    .put("version", AppLockVerifierFormat.VERSION)
                    .put("algorithm", "argon2id")
                    .put("memory_kib", AppLockVerifierFormat.MEMORY_KIB)
                    .put("iterations", AppLockVerifierFormat.ITERATIONS)
                    .put("parallelism", AppLockVerifierFormat.PARALLELISM)
                    .put("salt", encode(salt))
                    .put("verifier", encode(verifier))
                    .put("failures", 0)
                    .put("next_attempt_ms", 0L),
            )
            return "provisioned"
        } finally {
            verifier.fill(0)
        }
    }

    fun verify(pin: String, nowMillis: Long): JSONObject {
        if (!AppLockVerifierFormat.validPin(pin)) return JSONObject().put("status", "rejected")
        val record = readRecord()
        val nextAttempt = record.getLong("next_attempt_ms")
        if (nextAttempt > nowMillis) {
            return JSONObject().put("status", "cooldown").put("next_attempt_ms", nextAttempt)
        }
        val actual = derive(pin, decode(record.getString("salt")))
        val expected = decode(record.getString("verifier"))
        val accepted = try {
            MessageDigest.isEqual(expected, actual)
        } finally {
            actual.fill(0)
            expected.fill(0)
        }
        if (accepted) {
            record.put("failures", 0).put("next_attempt_ms", 0L)
            writeRecord(record)
            return JSONObject().put("status", "unlocked")
        }
        val failures = (record.getInt("failures") + 1).coerceAtMost(MAX_FAILURES)
        val cooldown = nowMillis + cooldownMillis(failures)
        record.put("failures", failures).put("next_attempt_ms", cooldown)
        writeRecord(record)
        return JSONObject().put("status", "cooldown").put("next_attempt_ms", cooldown)
    }

    private fun readRecord(): JSONObject = try {
        val encoded = preferences.getString(RECORD, null) ?: throw AppLockRecoveryRequiredException()
        val encrypted = decode(encoded)
        if (encrypted.size <= GCM_NONCE_BYTES) throw AppLockRecoveryRequiredException()
        val nonce = encrypted.copyOfRange(0, GCM_NONCE_BYTES)
        val ciphertext = encrypted.copyOfRange(GCM_NONCE_BYTES, encrypted.size)
        val plaintext = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, existingKey(), GCMParameterSpec(GCM_TAG_BITS, nonce))
            doFinal(ciphertext)
        }
        try {
            JSONObject(String(plaintext, StandardCharsets.UTF_8)).also(AppLockVerifierJson::validate)
        } finally {
            plaintext.fill(0)
        }
    } catch (_: AppLockRecoveryRequiredException) {
        throw AppLockRecoveryRequiredException()
    } catch (_: Exception) {
        throw AppLockRecoveryRequiredException()
    }

    private fun writeRecord(record: JSONObject) {
        AppLockVerifierJson.validate(record)
        val nonce = ByteArray(GCM_NONCE_BYTES).also(SecureRandom()::nextBytes)
        val plaintext = record.toString().toByteArray(StandardCharsets.UTF_8)
        try {
            val ciphertext = Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, keyForWrite(), GCMParameterSpec(GCM_TAG_BITS, nonce))
                doFinal(plaintext)
            }
            val payload = ByteArray(nonce.size + ciphertext.size)
            System.arraycopy(nonce, 0, payload, 0, nonce.size)
            System.arraycopy(ciphertext, 0, payload, nonce.size, ciphertext.size)
            if (!preferences.edit().putString(RECORD, encode(payload)).commit()) {
                throw AppLockRecoveryRequiredException()
            }
        } catch (_: AppLockRecoveryRequiredException) {
            throw AppLockRecoveryRequiredException()
        } catch (_: Exception) {
            throw AppLockRecoveryRequiredException()
        } finally {
            plaintext.fill(0)
        }
    }

    private fun derive(pin: String, salt: ByteArray): ByteArray {
        val pinBytes = pin.toByteArray(StandardCharsets.UTF_8)
        return try {
            ByteArray(VERIFIER_BYTES).also { output ->
                Argon2BytesGenerator().apply {
                    init(
                        Argon2Parameters.Builder(Argon2Parameters.ARGON2_id)
                            .withVersion(Argon2Parameters.ARGON2_VERSION_13)
                            .withSalt(salt)
                            .withMemoryAsKB(AppLockVerifierFormat.MEMORY_KIB)
                            .withIterations(AppLockVerifierFormat.ITERATIONS)
                            .withParallelism(AppLockVerifierFormat.PARALLELISM)
                            .build(),
                    )
                    generateBytes(pinBytes, output)
                }
            }
        } finally {
            pinBytes.fill(0)
        }
    }

    private fun existingKey(): SecretKey {
        val entry = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            .getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
            ?: throw AppLockRecoveryRequiredException()
        return entry.secretKey
    }

    private fun keyForWrite(): SecretKey {
        if (preferences.contains(RECORD)) return existingKey()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun cooldownMillis(failures: Int): Long {
        val minutes = (1L shl (failures - 1)).coerceAtMost(MAX_COOLDOWN_MINUTES)
        return minutes * 60_000L
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = try {
        Base64.decode(value, Base64.NO_WRAP)
    } catch (_: IllegalArgumentException) {
        throw AppLockRecoveryRequiredException()
    }

    private companion object {
        const val PREFERENCES = "app_lock_v1"
        const val RECORD = "record"
        const val KEY_ALIAS = "openpaycongo.app_lock.v1"
        const val VERIFIER_BYTES = 32
        const val GCM_NONCE_BYTES = 12
        const val GCM_TAG_BITS = 128
        const val MAX_FAILURES = AppLockVerifierFormat.MAX_FAILURES
        const val MAX_COOLDOWN_MINUTES = 15L
    }
}
