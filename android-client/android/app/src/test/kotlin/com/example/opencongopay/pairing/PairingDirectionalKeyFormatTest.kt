package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingDirectionalKeyFormatTest {
    @Test
    fun copiesExactlyTwoThirtyTwoByteDirectionalKeysIntoVersionedRecord() {
        val send = ByteArray(32) { 1 }
        val receive = ByteArray(32) { 2 }

        val record = PairingDirectionalKeyFormat.copyRecord(send, receive)

        assertEquals(65, record.size)
        assertEquals(1, record[0].toInt())
        assertArrayEquals(send, record.copyOfRange(1, 33))
        assertArrayEquals(receive, record.copyOfRange(33, 65))
        send.fill(9)
        receive.fill(9)
        assertEquals(1, record[1].toInt())
        assertEquals(2, record[33].toInt())
    }

    @Test
    fun rejectsMalformedDirectionalKeyLengths() {
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(ByteArray(31), ByteArray(32))
        }
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(ByteArray(32), ByteArray(33))
        }
    }
}
