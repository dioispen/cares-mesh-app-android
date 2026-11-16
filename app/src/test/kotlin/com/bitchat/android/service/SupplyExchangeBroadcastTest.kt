package com.bitchat.android.service

import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.mesh.MeshPacketUtils
import com.bitchat.android.protocol.MessageType
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.doReturn
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify

/** 物資需求／捐贈封包的組成與送出路徑。 */
class SupplyExchangeBroadcastTest {
    private val sender = "0011223344556677"
    private val payload = byteArrayOf(0x01, 0x01, 0x0A, 0x0B)

    @Test
    fun `a supply exchange goes out untagged, from us, with the same TTL as a Health Report`() {
        val packet = SupplyExchangeBroadcast.packet(sender, payload, timestamp = 1_700_000_000_500L)

        assertEquals(MessageType.SUPPLY_EXCHANGE.value, packet.type)
        assertEquals(HealthReportBroadcast.DEFAULT_TTL, packet.ttl)
        assertArrayEquals(MeshPacketUtils.hexStringToByteArray(sender), packet.senderID)
        assertEquals(null, packet.recipientID)
        assertEquals(1_700_000_000_500uL, packet.timestamp)
        assertArrayEquals(payload, packet.payload)
    }

    @Test
    fun `a mesh that is not running does not take the packet`() {
        val stopped = mock<BluetoothMeshService> { on { isStarted() } doReturn false }

        assertFalse(SupplyExchangeBroadcast.send(null, payload))
        assertFalse(SupplyExchangeBroadcast.send(stopped, payload))
        verify(stopped, never()).sendBroadcastPacket(any())
    }

    @Test
    fun `a running mesh signs and broadcasts it`() {
        val running = mock<BluetoothMeshService> {
            on { isStarted() } doReturn true
            on { myPeerID } doReturn sender
        }

        assertTrue(SupplyExchangeBroadcast.send(running, payload, timestamp = 1L))
        val sent = argumentCaptor<com.bitchat.android.protocol.BitchatPacket>()
        verify(running).sendBroadcastPacket(sent.capture())
        assertEquals(MessageType.SUPPLY_EXCHANGE.value, sent.firstValue.type)
        assertArrayEquals(payload, sent.firstValue.payload)
    }
}
