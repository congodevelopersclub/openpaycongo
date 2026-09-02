package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PairingConfirmedExchangeFormatTest {
    @Test
    fun `confirmed exchange restores only complete canonical native record`() {
        val exchange = ConfirmedPairingExchange(
            intent = ByteArray(16) { it.toByte() },
            canonicalServerBaseUrl = "https://pairing.example.test",
            sendKey = ByteArray(32) { 1 },
            receiveKey = ByteArray(32) { 2 },
            sas = "482901",
        )
        val record = PairingConfirmedExchangeFormat.copyRecord(exchange)
        val restored = PairingConfirmedExchangeFormat.readRecord(record)
        try {
            assertEquals("https://pairing.example.test", restored.canonicalServerBaseUrl)
            assertEquals("482901", restored.sas)
            assertArrayEquals(exchange.intent, restored.intent)
            assertArrayEquals(exchange.sendKey, restored.sendKey)
            assertArrayEquals(exchange.receiveKey, restored.receiveKey)
        } finally {
            exchange.dispose()
            restored.dispose()
            record.fill(0)
        }
    }

    @Test
    fun `confirmed exchange rejects altered record`() {
        val exchange = ConfirmedPairingExchange(
            intent = ByteArray(16),
            canonicalServerBaseUrl = "https://pairing.example.test",
            sendKey = ByteArray(32),
            receiveKey = ByteArray(32),
            sas = "482901",
        )
        val record = PairingConfirmedExchangeFormat.copyRecord(exchange)
        try {
            record[0] = 99
            assertThrows(PairingActivationException::class.java) {
                PairingConfirmedExchangeFormat.readRecord(record)
            }
        } finally {
            exchange.dispose()
            record.fill(0)
        }
    }

    @Test
    fun `confirmed exchange rejects invalid origin lengths and sas`() {
        fun exchange(
            origin: String = "https://pairing.example.test",
            intent: ByteArray = ByteArray(16),
            sendKey: ByteArray = ByteArray(32),
            receiveKey: ByteArray = ByteArray(32),
            sas: String = "482901",
        ) = ConfirmedPairingExchange(intent, origin, sendKey, receiveKey, sas)

        listOf(
            exchange(origin = "http://pairing.example.test"),
            exchange(origin = "https://pairing.example.test/"),
            exchange(intent = ByteArray(15)),
            exchange(sendKey = ByteArray(31)),
            exchange(receiveKey = ByteArray(33)),
            exchange(sas = "48290x"),
        ).forEach { candidate ->
            try {
                assertThrows(PairingActivationException::class.java) {
                    PairingConfirmedExchangeFormat.copyRecord(candidate)
                }
            } finally {
                candidate.dispose()
            }
        }

        val source = exchange()
        val valid = PairingConfirmedExchangeFormat.copyRecord(source)
        val truncated = valid.copyOf(valid.size - 1)
        try {
            assertThrows(PairingActivationException::class.java) {
                PairingConfirmedExchangeFormat.readRecord(truncated)
            }
        } finally {
            source.dispose()
            valid.fill(0)
            truncated.fill(0)
        }
    }

    @Test
    fun `recovery clear requires both atomic base and backup absence`() {
        val base = File.createTempFile("confirmed-exchange", ".record")
        val backup = File(base.path + ".bak")
        try {
            assertFalse(PairingConfirmedExchangeFiles.isAbsent(base))
            base.delete()
            backup.writeText("stale")
            assertFalse(PairingConfirmedExchangeFiles.isAbsent(base))
            backup.delete()
            assertTrue(PairingConfirmedExchangeFiles.isAbsent(base))
        } finally {
            base.delete()
            backup.delete()
        }
    }
}
