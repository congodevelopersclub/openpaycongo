package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.UUID

class MobileEnvelopeFormatTest {
    @Test
    fun wrapsOnlyDepositObjectPayloadIntoCanonicalEnvelopePlaintext() {
        val plaintext = MobileEnvelopeFormat.plaintext("deposit", "{\"amount_minor\":1250}".toByteArray(StandardCharsets.UTF_8))

        val envelope = JSONObject(String(plaintext, StandardCharsets.UTF_8))
        assertEquals(3, envelope.length())
        assertEquals(1, envelope.getInt("version"))
        assertEquals("deposit", envelope.getString("operation"))
        assertEquals(1250, envelope.getJSONObject("payload").getInt("amount_minor"))
    }

    @Test
    fun rejectsOtherOperationsMalformedOrOversizePayloads() {
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeFormat.plaintext("withdrawal", "{}".toByteArray())
        }
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeFormat.plaintext("deposit", "[]".toByteArray())
        }
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeFormat.plaintext("deposit", ByteArray(MobileEnvelopeFormat.MAX_PAYLOAD_BYTES + 1))
        }
    }

    @Test
    fun requestAadBindsDomainInstallationAndUnsignedCounter() {
        val installationId = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
        val aad = MobileEnvelopeFormat.requestAad(installationId, 42L)
        val domain = "openpaycongo/mobile/request-envelope/v1".toByteArray(StandardCharsets.UTF_8)
        val expected = ByteBuffer.allocate(2 + domain.size + 16 + 8)
            .putShort(domain.size.toShort())
            .put(domain)
            .putLong(0x123e4567e89b12d3L)
            .putLong(0xa456426614174000uL.toLong())
            .putLong(42L)
            .array()

        assertArrayEquals(expected, aad)
        assertEquals("42", MobileEnvelopeFormat.counterString(42L))
    }

    @Test
    fun counterPersistsStrictSuccessorAndFailsClosedAfterSignedServerMaximum() {
        assertEquals(2L, MobileEnvelopeCounter.nextAfter(1L))
        assertEquals(0L, MobileEnvelopeCounter.nextAfter(Long.MAX_VALUE))
        assertThrows(MobileEnvelopeException::class.java) { MobileEnvelopeCounter.nextAfter(0L) }
        assertThrows(MobileEnvelopeException::class.java) { MobileEnvelopeFormat.counterString(0L) }
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeFormat.requestAad(UUID.randomUUID(), -1L)
        }
    }

    @Test
}
