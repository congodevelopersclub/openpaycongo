package com.congodeveloperclub.opencongopay.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingDirectionalKeyFormatTest {
    @Test
    fun bindsCredentialIdentityAndDirectionalKeysIntoOneVersionedRecord() {
        val send = ByteArray(32) { 1 }
        val receive = ByteArray(32) { 2 }
        val installationId = "123e4567-e89b-12d3-a456-426614174000"
        val credential = PairingActivationCredential(installationId, "opaque-token")
        val authority = "https://pairing.example.test"

        val record = PairingDirectionalKeyFormat.copyRecord(credential, authority, send, receive)

        assertEquals(85 + "opaque-token".length + authority.length, record.size)
        assertEquals(4, record[0].toInt())
        val material = PairingDirectionalKeyFormat.outboundMaterial(record)
        assertEquals(installationId, material.installationId)
        assertEquals(authority, material.canonicalServerBaseUrl)
        assertArrayEquals(send, material.sendKey)
        send.fill(9)
        receive.fill(9)
        assertEquals(1, material.sendKey[0].toInt())
        material.dispose()
        val inbound = PairingDirectionalKeyFormat.inboundMaterial(record)
        assertEquals(installationId, inbound.installationId)
        assertArrayEquals(ByteArray(32) { 2 }, inbound.receiveKey)
        inbound.dispose()
    }

    @Test
    fun rejectsLegacyOriginlessRecordsToRequireRepairing() {
        val record = ByteArray(65)
        record[0] = 1
        ByteArray(32) { 3 }.copyInto(record, destinationOffset = 1)
        ByteArray(32) { 4 }.copyInto(record, destinationOffset = 33)

        assertThrows(PairingActivationException::class.java) {
            PairingDirectionalKeyFormat.outboundMaterial(record)
        }
    }

    @Test
    fun rejectsMalformedDirectionalKeyLengths() {
        val credential = PairingActivationCredential(
            "123e4567-e89b-12d3-a456-426614174000",
            "opaque-token",
        )
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(credential, "https://pairing.example.test", ByteArray(31), ByteArray(32))
        }
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(credential, "https://pairing.example.test", ByteArray(32), ByteArray(33))
        }
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(credential, "http://pairing.example.test", ByteArray(32), ByteArray(32))
        }
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(credential, "https://pairing.example.test/", ByteArray(32), ByteArray(32))
        }
    }
}
