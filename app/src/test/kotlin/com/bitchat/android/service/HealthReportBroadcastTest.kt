package com.bitchat.android.service

import com.bitchat.android.mesh.MeshPacketUtils
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.MessageType
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Health Report packet the bridge and the experiment sender (#70) both put on the mesh. */
class HealthReportBroadcastTest {
    private val sender = "0011223344556677"
    private val payload = byteArrayOf(0x01, 0x0A, 0x0B)

    @Test
    fun `a Health Report goes out tagged, from us, with the current TTL of 3`() {
        val packet = HealthReportBroadcast.packet(sender, payload, timestamp = 1_700_000_000_500L)

        assertEquals(MessageType.HEALTH_REPORT.value, packet.type)
        assertEquals(3, packet.ttl.toInt())
        assertArrayEquals(MeshPacketUtils.hexStringToByteArray(sender), packet.senderID)
        assertEquals(null, packet.recipientID)
        assertEquals(1_700_000_000_500uL, packet.timestamp)
        assertArrayEquals(byteArrayOf(BroadcastContentTag.HEALTH_REPORT.value) + payload, packet.payload)
    }

    @Test
    fun `only the TTL can be overridden`() {
        val packet = HealthReportBroadcast.packet(sender, payload, ttl = 7u, timestamp = 1L)

        assertEquals(7, packet.ttl.toInt())
        assertEquals(
            HealthReportBroadcast.packet(sender, payload, timestamp = 1L).copy(ttl = 7u),
            packet
        )
    }
}
