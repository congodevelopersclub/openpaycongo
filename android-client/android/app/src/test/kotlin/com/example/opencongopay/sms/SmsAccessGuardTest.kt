package com.congodeveloperclub.opencongopay.sms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class SmsAccessGuardTest {
    @Test
    fun rejectsRevokedPermissionBackgroundAndLockedAccess() {
        val guard = SmsAccessGuard()

        assertEquals(SmsAccessDenial.permissionRevoked, guard.check(permissionGranted = false))
        assertEquals(SmsAccessDenial.background, guard.check(permissionGranted = true))
        val generation = guard.onResume()
        assertEquals(SmsAccessDenial.locked, guard.check(permissionGranted = true))
        assertNull(guard.unlock(generation))
        assertNull(guard.check(permissionGranted = true))
        guard.onPause()
        assertEquals(SmsAccessDenial.background, guard.check(permissionGranted = true))
    }

    @Test
    fun staleAuthenticationCannotUnlockANewerForegroundGeneration() {
        val guard = SmsAccessGuard()
        val staleGeneration = guard.onResume()
        guard.onPause()
        val currentGeneration = guard.onResume()

        assertTrue(currentGeneration > staleGeneration)
        assertEquals(SmsAccessDenial.staleUnlock, guard.unlock(staleGeneration))
        assertEquals(SmsAccessDenial.locked, guard.check(permissionGranted = true))
        assertNull(guard.unlock(currentGeneration))
        assertNull(guard.check(permissionGranted = true))
    }

    @Test
    fun paymentBridgeCannotUseAnUnlockedGenerationAfterPauseOrRelock() {
        val guard = SmsAccessGuard()
        val generation = guard.onResume()
        assertNull(guard.unlock(generation))
        assertNull(guard.check(permissionGranted = true, expectedGeneration = generation))

        guard.onPause()
        assertEquals(SmsAccessDenial.background, guard.check(permissionGranted = true, expectedGeneration = generation))
        guard.onResume()
        assertEquals(SmsAccessDenial.locked, guard.check(permissionGranted = true))
    }

    @Test
    fun pauseConcurrentWithSensitiveSealWaitsForTheGuardHeldLease() {
        val guard = SmsAccessGuard()
        val generation = guard.onResume()
        assertNull(guard.unlock(generation))
        val lease = guard.lease(permissionGranted = { true }, expectedGeneration = generation)
        val sealStarted = CountDownLatch(1)
        val releaseSeal = CountDownLatch(1)
        val pauseAttempted = CountDownLatch(1)
        val pauseFinished = CountDownLatch(1)
        val keyUses = AtomicInteger()
        val nativeUses = AtomicInteger()

        val seal = Thread {
            lease.use {
                keyUses.incrementAndGet()
                sealStarted.countDown()
                check(releaseSeal.await(2, TimeUnit.SECONDS))
                nativeUses.incrementAndGet()
            }
        }
        val pause = Thread {
            pauseAttempted.countDown()
            guard.onPause()
            pauseFinished.countDown()
        }
        seal.start()
        assertTrue(sealStarted.await(2, TimeUnit.SECONDS))
        pause.start()
        assertTrue(pauseAttempted.await(2, TimeUnit.SECONDS))
        assertFalse(pauseFinished.await(100, TimeUnit.MILLISECONDS))

        releaseSeal.countDown()
        seal.join(2_000)
        pause.join(2_000)

        assertFalse(seal.isAlive)
        assertFalse(pause.isAlive)
        assertEquals(1, keyUses.get())
        assertEquals(1, nativeUses.get())
        assertEquals(SmsAccessDenial.background, guard.check(permissionGranted = true, expectedGeneration = generation))
    }
}
