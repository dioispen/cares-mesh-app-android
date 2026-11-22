package com.bitchat.android.service

import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.mesh.MeshPacketUtils
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.util.AppConstants
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.doReturn
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify

/** The Health Report packet the bridge and the experiment sender (#70) both put on the mesh. */
class HealthReportBroadcastTest {
    private val sender = "0011223344556677"
    private val payload = byteArrayOf(0x01, 0x0A, 0x0B)

    @Test
    fun `a Health Report goes out tagged, from us, with the upstream TTL of 7`() {
        val packet = HealthReportBroadcast.packet(sender, payload, timestamp = 1_700_000_000_500L)

        assertEquals(MessageType.HEALTH_REPORT.value, packet.type)
        assertEquals(7, packet.ttl.toInt())
        assertArrayEquals(MeshPacketUtils.hexStringToByteArray(sender), packet.senderID)
        assertEquals(null, packet.recipientID)
        assertEquals(1_700_000_000_500uL, packet.timestamp)
        assertArrayEquals(byteArrayOf(BroadcastContentTag.HEALTH_REPORT.value) + payload, packet.payload)
    }

    @Test
    fun `a Health Report goes out with the same TTL as any other bitchat broadcast`() {
        // ADR-0014：Health Report 不另設 TTL，沿用上游 bitchat 的 MESSAGE_TTL_HOPS。要偏離它，
        // 先推翻 ADR-0014，再改 HEALTH_REPORT_TTL_HOPS 與這個測試。
        assertEquals(AppConstants.MESSAGE_TTL_HOPS, HealthReportBroadcast.DEFAULT_TTL)
    }

    @Test
    fun `a mesh that is not running does not take the report`() {
        val stopped = mock<BluetoothMeshService> { on { isStarted() } doReturn false }

        assertFalse(HealthReportBroadcast.send(null, payload))
        assertFalse(HealthReportBroadcast.send(stopped, payload))
        verify(stopped, never()).sendBroadcastPacket(any())
    }

    @Test
    fun `only the TTL can be overridden`() {
        val packet = HealthReportBroadcast.packet(sender, payload, ttl = 3u, timestamp = 1L)

        assertEquals(3, packet.ttl.toInt())
        assertEquals(
            HealthReportBroadcast.packet(sender, payload, timestamp = 1L).copy(ttl = 3u),
            packet
        )
    }
}
