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

        assertEquals(86 + "opaque-token".length + authority.length, record.size)
        assertEquals(5, record[0].toInt())
        assertThrows(PairingActivationException::class.java) {
            PairingDirectionalKeyFormat.outboundMaterial(record)
        }
        val material = PairingDirectionalKeyFormat.pendingActivationAcknowledgementOutboundMaterial(record)
        assertEquals(installationId, material.installationId)
        assertEquals(authority, material.canonicalServerBaseUrl)
        assertArrayEquals(send, material.sendKey)
        send.fill(9)
        receive.fill(9)
        assertEquals(1, material.sendKey[0].toInt())
        material.dispose()
        val inbound = PairingDirectionalKeyFormat.pendingActivationAcknowledgementInboundMaterial(record)
        assertEquals(installationId, inbound.installationId)
        assertArrayEquals(ByteArray(32) { 2 }, inbound.receiveKey)
        inbound.dispose()

        PairingDirectionalKeyFormat.markActivationAcknowledged(record)
        val activated = PairingDirectionalKeyFormat.outboundMaterial(record)
        assertEquals(installationId, activated.installationId)
        activated.dispose()
        assertThrows(PairingActivationException::class.java) {
            PairingDirectionalKeyFormat.pendingActivationAcknowledgementOutboundMaterial(record)
        }
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
    fun migratesV4ToPendingAcknowledgementWithoutChangingProtectedMaterial() {
        val credential = PairingActivationCredential(
            "123e4567-e89b-12d3-a456-426614174000",
            "opaque-token",
        )
        val v5 = PairingDirectionalKeyFormat.copyRecord(
            credential,
            "https://pairing.example.test",
            ByteArray(32) { 3 },
            ByteArray(32) { 4 },
        )
        val v4 = ByteArray(v5.size - 1).also { record ->
            record[0] = 4
            System.arraycopy(v5, 2, record, 1, record.size - 1)
        }

        val migrated = PairingDirectionalKeyFormat.migrateV4ToV5(v4)

        assertEquals(5, migrated[0].toInt())
        assertEquals(0, migrated[1].toInt())
        assertThrows(PairingActivationException::class.java) {
            PairingDirectionalKeyFormat.outboundMaterial(migrated)
        }
        val pending = PairingDirectionalKeyFormat.pendingActivationAcknowledgementOutboundMaterial(migrated)
        assertEquals("123e4567-e89b-12d3-a456-426614174000", pending.installationId)
        assertEquals("https://pairing.example.test", pending.canonicalServerBaseUrl)
        assertArrayEquals(ByteArray(32) { 3 }, pending.sendKey)
        pending.dispose()
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
