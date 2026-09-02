package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingDirectionalKeyFormatTest {
    @Test
    fun bindsInstallationIdentityAndDirectionalKeysIntoOneVersionedRecord() {
        val send = ByteArray(32) { 1 }
        val receive = ByteArray(32) { 2 }
        val installationId = "123e4567-e89b-12d3-a456-426614174000"

        val record = PairingDirectionalKeyFormat.copyRecord(installationId, send, receive)

        assertEquals(81, record.size)
        assertEquals(2, record[0].toInt())
        val material = PairingDirectionalKeyFormat.outboundMaterial(record)
        assertEquals(installationId, material.installationId)
        assertArrayEquals(send, material.sendKey)
        send.fill(9)
        receive.fill(9)
        assertEquals(1, material.sendKey[0].toInt())
        material.dispose()
    }

    @Test
    fun rejectsMalformedDirectionalKeyLengths() {
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord("123e4567-e89b-12d3-a456-426614174000", ByteArray(31), ByteArray(32))
        }
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord("123e4567-e89b-12d3-a456-426614174000", ByteArray(32), ByteArray(33))
        }
    }
}
