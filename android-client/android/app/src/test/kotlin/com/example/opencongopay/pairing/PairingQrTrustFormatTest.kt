package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

class PairingQrTrustFormatTest {
    @Test
    fun acceptsOnlyCanonicalSha256Base64urlFingerprints() {
        val valid = "Fs81cR1vRgNPZbGmGrwneKW5Th0PkADWm8jyzB6fhI0"
        assertEquals(valid, PairingQrTrustFormat.canonicalFingerprint(valid, api24Base64))
        assertThrows(PairingQrTrustStorageException::class.java) {
            PairingQrTrustFormat.canonicalFingerprint("$valid=", api24Base64)
        }
        assertThrows(PairingQrTrustStorageException::class.java) {
            PairingQrTrustFormat.canonicalFingerprint("A".repeat(42), api24Base64)
        }
    }

    @Test
    fun acceptsAndroidApi24UrlSafeUnpaddedFingerprintAlphabet() {
        val urlSafe = "${"_".repeat(42)}8"
        assertEquals(urlSafe, PairingQrTrustFormat.canonicalFingerprint(urlSafe, api24Base64))
        assertThrows(PairingQrTrustStorageException::class.java) {
            PairingQrTrustFormat.canonicalFingerprint("/".repeat(43), api24Base64)
        }
    }

    private val api24Base64 = object : PairingQrTrustBase64 {
        override fun decodeUrlSafeUnpadded(value: String): ByteArray =
            Base64.getUrlDecoder().decode(value)

        override fun encodeUrlSafeUnpadded(value: ByteArray): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(value)
    }
}
