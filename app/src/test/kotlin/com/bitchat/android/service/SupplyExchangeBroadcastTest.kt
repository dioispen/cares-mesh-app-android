package com.bitchat.android.service

import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.mesh.MeshPacketUtils
import com.bitchat.android.protocol.MessageType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.doReturn
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify

class SupplyExchangeBroadcastTest {
    @Test
    fun `supply exchange broadcast uses its packet type and seven hop ttl`() {
        val packet = SupplyExchangeBroadcast.packet(
            senderID = "0011223344556677",
            payload = byteArrayOf(1, 1, 2),
            timestamp = 1234L
        )

        assertEquals(MessageType.SUPPLY_EXCHANGE.value, packet.type)
        assertEquals(7, packet.ttl.toInt())
        assertEquals(MeshPacketUtils.hexStringToByteArray("0011223344556677").toList(), packet.senderID.toList())
        assertEquals(1234uL, packet.timestamp)
    }

    @Test
    fun `stopped mesh does not accept a supply packet`() {
        val stopped = mock<BluetoothMeshService> { on { isStarted() } doReturn false }

        assertFalse(SupplyExchangeBroadcast.send(null, byteArrayOf(1)))
        assertFalse(SupplyExchangeBroadcast.send(stopped, byteArrayOf(1)))
        verify(stopped, never()).sendBroadcastPacket(any())
    }

    @Test
    fun `running mesh accepts a supply packet`() {
        val running = mock<BluetoothMeshService> {
            on { isStarted() } doReturn true
            on { myPeerID } doReturn "0011223344556677"
        }

        assertTrue(SupplyExchangeBroadcast.send(running, byteArrayOf(1, 1, 2)))
        verify(running).sendBroadcastPacket(any())
    }
}
