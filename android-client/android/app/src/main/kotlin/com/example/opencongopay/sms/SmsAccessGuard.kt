package com.congodeveloperclub.opencongopay.sms

internal enum class SmsAccessDenial { permissionRevoked, background, locked, staleUnlock }

internal class SmsAccessGuard {
    private var foreground = false
    private var unlockedGeneration: Long? = null
    private var generation = 0L

    @Synchronized
    fun onResume(): Long {
        generation = if (generation == Long.MAX_VALUE) 1L else generation + 1L
        foreground = true
        unlockedGeneration = null
        return generation
    }

    @Synchronized
    fun onPause() {
        foreground = false
        unlockedGeneration = null
    }

    @Synchronized
    fun currentGeneration(): Long = generation

    @Synchronized
    fun lock() {
        unlockedGeneration = null
    }

    @Synchronized
    fun unlock(authenticatedGeneration: Long): SmsAccessDenial? {
        if (!foreground || authenticatedGeneration != generation) {
            return SmsAccessDenial.staleUnlock
        }
        unlockedGeneration = generation
        return null
    }

    @Synchronized
    fun check(permissionGranted: Boolean, expectedGeneration: Long? = null): SmsAccessDenial? = when {
        !permissionGranted -> SmsAccessDenial.permissionRevoked
        !foreground -> SmsAccessDenial.background
        expectedGeneration != null && expectedGeneration != generation -> SmsAccessDenial.staleUnlock
        unlockedGeneration != generation -> SmsAccessDenial.locked
        else -> null
    }
}
