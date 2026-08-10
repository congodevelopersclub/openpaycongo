package com.congodeveloperclub.opencongopay.sms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
