package com.congodeveloperclub.opencongopay.lock

import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class AppLockVerifierFormatTest {
    @Test
    fun v1AcceptsOnlyTheExactArgon2idCostItDerives() {
        AppLockVerifierFormat.validate(record())
        assertThrows(AppLockRecoveryRequiredException::class.java) {
            AppLockVerifierFormat.validate(record(memoryKib = 128 * 1024))
        }
        assertThrows(AppLockRecoveryRequiredException::class.java) {
            AppLockVerifierFormat.validate(record(iterations = 4))
        }
    }

    @Test
    fun pinIsExactlySixAsciiDigits() {
        assertTrue(AppLockVerifierFormat.validPin("123456"))
        assertFalse(AppLockVerifierFormat.validPin("１２３４５６"))
        assertFalse(AppLockVerifierFormat.validPin("12345a"))
        assertFalse(AppLockVerifierFormat.validPin("12345"))
    }

    private fun record(
        memoryKib: Int = AppLockVerifierFormat.MEMORY_KIB,
        iterations: Int = AppLockVerifierFormat.ITERATIONS,
    ): AppLockVerifierRecord = AppLockVerifierRecord(
        version = AppLockVerifierFormat.VERSION,
        algorithm = "argon2id",
        memoryKib = memoryKib,
        iterations = iterations,
        parallelism = AppLockVerifierFormat.PARALLELISM,
        salt = Base64.getEncoder().encodeToString(ByteArray(AppLockVerifierFormat.SALT_BYTES)),
        verifier = Base64.getEncoder().encodeToString(ByteArray(AppLockVerifierFormat.VERIFIER_BYTES)),
        failures = 0,
        nextAttemptMillis = 0L,
    )
}
