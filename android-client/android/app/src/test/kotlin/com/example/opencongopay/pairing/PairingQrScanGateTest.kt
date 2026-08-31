package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingQrScanGateTest {
    @Test
    fun `delivers one bounded raw QR and drops a duplicate callback`() {
        val delivered = mutableListOf<PairingQrScanOutcome>()
        val gate = PairingQrScanGate()

        assertTrue(gate.begin(delivered::add))
        gate.succeed("bounded-qr")
        gate.succeed("second-qr")

        assertEquals(listOf(PairingQrScanOutcome.Raw("bounded-qr")), delivered)
    }

    @Test
    fun `cancellation and activity destruction finish without QR material`() {
        val delivered = mutableListOf<PairingQrScanOutcome>()
        val gate = PairingQrScanGate()

        assertTrue(gate.begin(delivered::add))
        gate.cancel()
        assertEquals(listOf(PairingQrScanOutcome.Cancelled), delivered)

        assertTrue(gate.begin(delivered::add))
        gate.fail()
        assertEquals(PairingQrScanOutcome.Unavailable, delivered.last())
    }

    @Test
    fun `refuses overlapping and oversized scanner results`() {
        val delivered = mutableListOf<PairingQrScanOutcome>()
        val gate = PairingQrScanGate()

        assertTrue(gate.begin(delivered::add))
        assertFalse(gate.begin(delivered::add))
        gate.succeed("x".repeat(4097))

        assertEquals(listOf(PairingQrScanOutcome.Unavailable), delivered)
    }
}
