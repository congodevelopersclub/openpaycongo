package com.congodeveloperclub.opencongopay.sms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SenderRulesTest {
    @Test
    fun acceptsOnlyExactE164OrBoundedAsciiSenderIds() {
        assertEquals("+243990001111", SenderRules.normalize("+243990001111"))
        assertEquals("ORANGE", SenderRules.normalize("ORANGE"))
        assertNull(SenderRules.normalize("Orange"))
        assertNull(SenderRules.normalize("ORANGE*") )
        assertNull(SenderRules.normalize("ORANGЕ"))
        assertNull(SenderRules.normalize("+043990001111"))
        assertNull(SenderRules.normalize("AB"))
        assertNull(SenderRules.normalize("ABCDEFGHIJKL"))
    }

    @Test
    fun captureBoundsAreInclusiveAndRejectOversizeAgeFutureAndSegments() {
        val now = 2_000_000_000_000L
        assertEquals(true, SmsCapturePolicy.accepts(now, now, 1, 0))
        assertEquals(true, SmsCapturePolicy.accepts(now, now, 8, 4096))
        assertEquals(false, SmsCapturePolicy.accepts(now, now, 9, 10))
        assertEquals(false, SmsCapturePolicy.accepts(now, now, 1, 4097))
        assertEquals(false, SmsCapturePolicy.accepts(now - 31L * 24L * 60L * 60L * 1000L - 1L, now, 1, 10))
        assertEquals(false, SmsCapturePolicy.accepts(now + 5L * 60L * 1000L + 1L, now, 1, 10))
    }
}
