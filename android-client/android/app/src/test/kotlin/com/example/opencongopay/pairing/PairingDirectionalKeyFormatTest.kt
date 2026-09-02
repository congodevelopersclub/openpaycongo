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

        val record = PairingDirectionalKeyFormat.copyRecord(credential, send, receive)

        assertEquals(95, record.size)
        assertEquals(3, record[0].toInt())
        val material = PairingDirectionalKeyFormat.outboundMaterial(record)
        assertEquals(installationId, material.installationId)
        assertArrayEquals(send, material.sendKey)
        send.fill(9)
        receive.fill(9)
        assertEquals(1, material.sendKey[0].toInt())
        material.dispose()
    }

    @Test
    fun readsTheShippedKeyOnlyLegacyGenerationNeededForAnAtomicUpgrade() {
        val installationId = "123e4567-e89b-12d3-a456-426614174000"
        val record = ByteArray(65)
        record[0] = 1
        ByteArray(32) { 3 }.copyInto(record, destinationOffset = 1)
        ByteArray(32) { 4 }.copyInto(record, destinationOffset = 33)

        val generation = PairingDirectionalKeyFormat.legacyGeneration(
            installationId,
            record,
        )

        assertEquals(installationId, generation.installationId)
        assertEquals(3, generation.sendKey[0].toInt())
        assertEquals(4, generation.receiveKey[0].toInt())
        generation.dispose()
    }

    @Test
    fun rejectsMalformedDirectionalKeyLengths() {
        val credential = PairingActivationCredential(
            "123e4567-e89b-12d3-a456-426614174000",
            "opaque-token",
        )
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(credential, ByteArray(31), ByteArray(32))
        }
        assertThrows(PairingDirectionalKeyStorageException::class.java) {
            PairingDirectionalKeyFormat.copyRecord(credential, ByteArray(32), ByteArray(33))
        }
    }
}
