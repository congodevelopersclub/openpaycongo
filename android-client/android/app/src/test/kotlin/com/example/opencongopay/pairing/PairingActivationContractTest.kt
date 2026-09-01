package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.nio.charset.StandardCharsets

class PairingActivationContractTest {
    @Test
    fun `activation AAD binds versioned domain and raw intent`() {
        val intent = ByteArray(16) { it.toByte() }

        val aad = PairingActivationEnvelope.aad(intent)

        val domain = "openpaycongo/pairing/activation-response/v2".toByteArray(StandardCharsets.UTF_8)
        assertEquals(43, domain.size)
        assertEquals(0, aad[0].toInt())
        assertEquals(43, aad[1].toInt())
        assertArrayEquals(domain, aad.copyOfRange(2, 45))
        assertEquals(0, aad[45].toInt())
        assertEquals(16, aad[46].toInt())
        assertArrayEquals(intent, aad.copyOfRange(47, 63))
    }

    @Test
    fun `credential plaintext accepts only exact v2 shape`() {
        val credential = PairingActivationCredential.parse(
            "{\"version\":2,\"installation_id\":\"123e4567-e89b-12d3-a456-426614174000\",\"bearer_token\":\"opaque-token\"}".toByteArray(),
        )

        assertEquals("123e4567-e89b-12d3-a456-426614174000", credential.installationId)
        assertThrows(PairingActivationException::class.java) {
            PairingActivationCredential.parse(
                "{\"version\":2,\"installation_id\":\"123e4567-e89b-12d3-a456-426614174000\",\"bearer_token\":\"opaque-token\",\"extra\":true}".toByteArray(),
            )
        }
    }
}
