package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingQrTrustFormatTest {
    @Test
    fun acceptsOnlyCanonicalSha256Base64urlFingerprints() {
        val valid = "Fs81cR1vRgNPZbGmGrwneKW5Th0PkADWm8jyzB6fhI0"
        assertEquals(valid, PairingQrTrustFormat.canonicalFingerprint(valid))
        assertThrows(PairingQrTrustStorageException::class.java) {
            PairingQrTrustFormat.canonicalFingerprint("$valid=")
        }
        assertThrows(PairingQrTrustStorageException::class.java) {
            PairingQrTrustFormat.canonicalFingerprint("A".repeat(42))
        }
    }
}
