package com.bitchat.android.protocol

import org.junit.Assert.*
import org.junit.Test

class DisasterReportTest {

    @Test
    fun testPayloadEncodingAndDecoding() {
        val original = HealthReportPayload(
            reporterId = "TEST-ID-999",
            name = "Test User",
            phone = "0912345678",
            bloodType = "A",
            status = "輕傷",
            description = "Need immediate assistance and water.",
            lat = 25.0330,
            lng = 121.5654,
            reportTime = "2021-07-01T00:00:00Z"
        )

        val encoded = original.encode()
        assertNotNull(encoded)
        assertTrue(encoded.isNotEmpty())

        val decoded = HealthReportPayload.decode(encoded)

        assertNotNull(decoded)
        assertEquals(original.reporterId, decoded?.reporterId)
        assertEquals(original.name, decoded?.name)
        assertEquals(original.phone, decoded?.phone)
        assertEquals(original.bloodType, decoded?.bloodType)
        assertEquals(original.status, decoded?.status)
        assertEquals(original.description, decoded?.description)
        assertEquals(original.lat, decoded?.lat)
        assertEquals(original.lng, decoded?.lng)
        assertEquals(original.reportTime, decoded?.reportTime)
    }

    @Test
    fun testBitchatPacketIntegration() {
        val payload = HealthReportPayload(
            reporterId = "MSG-001",
            name = "User",
            phone = "0900000000",
            bloodType = null,
            status = "安全",
            description = "Relay test",
            lat = 25.0,
            lng = 121.0,
            reportTime = "2021-07-01T00:00:00Z"
        )

        val senderID = ByteArray(8) { 0x01.toByte() }
        val encodedPayload = payload.encode()

        val packet = BitchatPacket(
            version = 1u,
            type = MessageType.HEALTH_REPORT.value,
            senderID = senderID,
            recipientID = null,
            timestamp = System.currentTimeMillis().toULong(),
            payload = encodedPayload,
            ttl = 7u
        )

        assertEquals(0x30, MessageType.HEALTH_REPORT.value.toInt())
        assertEquals(MessageType.HEALTH_REPORT.value.toInt(), packet.type.toInt())

        val decodedPayload = HealthReportPayload.decode(packet.payload)
        assertNotNull(decodedPayload)
        assertEquals("MSG-001", decodedPayload?.reporterId)
        assertEquals("安全", decodedPayload?.status)
    }

    @Test
    fun testEdgeCaseEmptyOptionalFields() {
        val payload = HealthReportPayload(
            reporterId = "ID",
            name = "N",
            phone = "P",
            bloodType = null,
            status = "重傷",
            description = null,
            lat = null,
            lng = null,
            reportTime = "2000-01-01T00:00:00Z"
        )

        val encoded = payload.encode()
        val decoded = HealthReportPayload.decode(encoded)

        assertNotNull(decoded)
        assertNull(decoded?.bloodType)
        assertNull(decoded?.description)
        assertNull(decoded?.lat)
        assertNull(decoded?.lng)
    }

    @Test
    fun testInvalidDataDecoding() {
        val junkData = byteArrayOf(0x01, 0x02, 0x03)
        val decoded = HealthReportPayload.decode(junkData)
        assertNull(decoded)
    }
}
