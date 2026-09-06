package com.congodeveloperclub.opencongopay.pairing

import com.congodeveloperclub.opencongopay.sms.SmsAccessGuard
import com.congodeveloperclub.opencongopay.sms.SmsAccessLeaseException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class PairingActivationAcknowledgementAccessTest {
    @Test
    fun `revoked access prevents acknowledgement sealing before protected material is touched`() {
        val guard = SmsAccessGuard()
        val generation = guard.onResume()
        assertEquals(null, guard.unlock(generation))
        val acknowledgement = PairingActivationAcknowledgementAccess(
            guard.lease(permissionGranted = { true }, expectedGeneration = generation),
        )
        guard.onPause()
        val keyUses = AtomicInteger()
        val persistedAcknowledgements = AtomicInteger()
        val activations = AtomicInteger()

        assertThrows(SmsAccessLeaseException::class.java) {
            acknowledgement.seal {
                keyUses.incrementAndGet()
                persistedAcknowledgements.incrementAndGet()
                activations.incrementAndGet()
            }
        }

        assertEquals(0, keyUses.get())
        assertEquals(0, persistedAcknowledgements.get())
        assertEquals(0, activations.get())
    }

    @Test
    fun `stale callback cannot open persist acknowledgement or activate after relock`() {
        val guard = SmsAccessGuard()
        val staleGeneration = guard.onResume()
        assertEquals(null, guard.unlock(staleGeneration))
        val acknowledgement = PairingActivationAcknowledgementAccess(
            guard.lease(permissionGranted = { true }, expectedGeneration = staleGeneration),
        )
        guard.onPause()
        val currentGeneration = guard.onResume()
        assertEquals(null, guard.unlock(currentGeneration))
        val keyUses = AtomicInteger()
        val persistedAcknowledgements = AtomicInteger()
        val activations = AtomicInteger()

        assertThrows(SmsAccessLeaseException::class.java) {
            acknowledgement.open {
                keyUses.incrementAndGet()
                persistedAcknowledgements.incrementAndGet()
                activations.incrementAndGet()
            }
        }

        assertEquals(0, keyUses.get())
        assertEquals(0, persistedAcknowledgements.get())
        assertEquals(0, activations.get())
    }
}
