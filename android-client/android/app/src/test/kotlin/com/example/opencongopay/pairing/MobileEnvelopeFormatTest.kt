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
    fun responseAadBindsDomainInstallationCounterAndHttpStatus() {
        val installationId = UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
        val aad = MobileEnvelopeFormat.responseAad(installationId, 42L, 201)
        val domain = "openpaycongo/mobile/response-envelope/v1".toByteArray(StandardCharsets.UTF_8)
        val expected = ByteBuffer.allocate(2 + domain.size + 16 + 8 + 2)
            .putShort(domain.size.toShort())
            .put(domain)
            .putLong(0x123e4567e89b12d3L)
            .putLong(0xa456426614174000uL.toLong())
            .putLong(42L)
            .putShort(201.toShort())
            .array()

        assertArrayEquals(expected, aad)
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeFormat.responseAad(installationId, 42L, 404)
        }
    }

    @Test
    fun responseOutcomeRequiresTheStatusAuthenticatedByTheEnvelope() {
        assertEquals(
            "recorded",
            MobileEnvelopeFormat.responseOutcome(201, "{\"outcome\":\"recorded\"}".toByteArray()),
        )
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeFormat.responseOutcome(200, "{\"outcome\":\"recorded\"}".toByteArray())
        }
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeFormat.responseOutcome(201, "{\"outcome\":\"recorded\",\"extra\":true}".toByteArray())
        }
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
    fun counterReservationPersistsBeforeReturnAndContinuesAfterRestart() {
        val store = InMemoryCounterStore()

        assertEquals(1L, MobileEnvelopeCounterAllocator(store).reserve())
        assertEquals(listOf(2L), store.persisted)
        assertEquals(2L, MobileEnvelopeCounterAllocator(store).reserve())
        assertEquals(listOf(2L, 3L), store.persisted)
    }

    @Test
    fun counterReservationNeverReturnsAnUnpersistedOrExhaustedValue() {
        val failedWrite = InMemoryCounterStore(failWrites = true)
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeCounterAllocator(failedWrite).reserve()
        }
        assertEquals(null, failedWrite.next)

        val exhausted = InMemoryCounterStore(Long.MAX_VALUE)
        assertEquals(Long.MAX_VALUE, MobileEnvelopeCounterAllocator(exhausted).reserve())
        assertEquals(0L, exhausted.next)
        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeCounterAllocator(exhausted).reserve()
        }

        assertThrows(MobileEnvelopeException::class.java) {
            MobileEnvelopeCounterAllocator(InMemoryCounterStore(-1L)).reserve()
        }
    }
}

private class InMemoryCounterStore(
    initial: Long? = null,
    private val failWrites: Boolean = false,
) : MobileEnvelopeCounterStore {
    var next: Long? = initial
    val persisted = mutableListOf<Long>()

    override fun readNext(): Long? = next

    override fun persistNext(next: Long) {
        if (failWrites) throw MobileEnvelopeException()
        persisted += next
        this.next = next
    }
}
