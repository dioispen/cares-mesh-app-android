
package com.bitchat.android.mesh

import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.util.AppConstants
import com.bitchat.android.util.toHexString
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever
import kotlin.random.Random

@ExperimentalCoroutinesApi
class PacketRelayManagerTest {

    private lateinit var packetRelayManager: PacketRelayManager
    private val delegate: PacketRelayManagerDelegate = mock()

    private val myPeerID = "1111111111111111"
    private val otherPeerID = "2222222222222222"
    private val nextHopPeerID = "3333333333333333"
    private val finalRecipientID = "4444444444444444"

    @Before
    fun setUp() {
        packetRelayManager = PacketRelayManager(myPeerID)
        packetRelayManager.delegate = delegate
        whenever(delegate.getNetworkSize()).thenReturn(10)
        whenever(delegate.getBroadcastRecipient()).thenReturn(byteArrayOf(0,0,0,0,0,0,0,0))
    }

    private fun createPacket(route: List<ByteArray>?, recipient: String? = null): BitchatPacket {
        return BitchatPacket(
            type = MessageType.MESSAGE.value,
            senderID = hexStringToPeerBytes(otherPeerID),
            recipientID = recipient?.let { hexStringToPeerBytes(it) },
            timestamp = System.currentTimeMillis().toULong(),
            payload = "hello".toByteArray(),
            ttl = 5u,
            route = route
        )
    }

    @Test
    fun `packet with duplicate hops is dropped`() = runTest {
        val route = listOf(
            hexStringToPeerBytes(nextHopPeerID),
            hexStringToPeerBytes(nextHopPeerID)
        )
        val packet = createPacket(route)
        val routedPacket = RoutedPacket(packet, otherPeerID)

        packetRelayManager.handlePacketRelay(routedPacket)

        verify(delegate, never()).sendToPeer(any(), any())
        verify(delegate, never()).broadcastPacket(any())
    }

    @Test
    fun `valid source-routed packet is relayed to next hop`() = runTest {
        val route = listOf(
            hexStringToPeerBytes(myPeerID),
            hexStringToPeerBytes(nextHopPeerID)
        )
        val packet = createPacket(route, finalRecipientID)
        val routedPacket = RoutedPacket(packet, otherPeerID)
        whenever(delegate.sendToPeer(any(), any())).thenReturn(true)

        packetRelayManager.handlePacketRelay(routedPacket)

        verify(delegate).sendToPeer(org.mockito.kotlin.eq(nextHopPeerID), any())
        verify(delegate, never()).broadcastPacket(any())
    }

    @Test
    fun `last hop does not relay further`() = runTest {
        val route = listOf(
            hexStringToPeerBytes(myPeerID)
        )
        val packet = createPacket(route, finalRecipientID)
        val routedPacket = RoutedPacket(packet, otherPeerID)
        whenever(delegate.sendToPeer(any(), any())).thenReturn(true)

        packetRelayManager.handlePacketRelay(routedPacket)

        verify(delegate).sendToPeer(org.mockito.kotlin.eq(finalRecipientID), any())
        verify(delegate, never()).broadcastPacket(any())
    }
    
    @Test
    fun `packet with empty route is broadcast`() = runTest {
        val packet = createPacket(null)
        val routedPacket = RoutedPacket(packet, otherPeerID)

        packetRelayManager.handlePacketRelay(routedPacket)

        verify(delegate, never()).sendToPeer(any(), any())
        verify(delegate).broadcastPacket(any())
    }

    // Relay Decision 的政策參數（#1 R13）。「收到的 TTL」在轉發前先扣 1，門檻比的是扣完的值。

    @Test
    fun `the default policy keeps today's unconditional relay threshold of 4`() = runTest {
        assertEquals(4, RelayPolicy().unconditionalRelayTtl.toInt())

        val relay = RelayUnderTest(random = NeverWinsTheDraw)

        assertTrue("received 5, relayed as 4", relay.relays(receivedTtl = 5u))
        assertFalse("received 4, relayed as 3", relay.relays(receivedTtl = 4u))
    }

    @Test
    fun `a packet whose relayed TTL reaches the threshold is relayed unconditionally`() = runTest {
        val relay = RelayUnderTest(RelayPolicy(unconditionalRelayTtl = 6u), NeverWinsTheDraw)

        assertTrue("relayed TTL == threshold", relay.relays(receivedTtl = 7u))
        assertFalse("relayed TTL == threshold - 1", relay.relays(receivedTtl = 6u))
    }

    @Test
    fun `a threshold above every TTL puts every hop through the network-size probability`() = runTest {
        val relay = RelayUnderTest(RelayPolicy(unconditionalRelayTtl = UByte.MAX_VALUE), NeverWinsTheDraw)

        assertFalse(relay.relays(receivedTtl = AppConstants.MESSAGE_TTL_HOPS))
        assertFalse(relay.relays(receivedTtl = UByte.MAX_VALUE))
    }

    @Test
    fun `the same seed gives the same probabilistic Relay Decisions`() = runTest {
        suspend fun decisions(seed: Int): List<Boolean> {
            val relay = RelayUnderTest(random = Random(seed))
            return List(64) { relay.relays(receivedTtl = 3u) }
        }

        val first = decisions(seed = 42)

        assertEquals(first, decisions(seed = 42))
        assertTrue("the probabilistic path both relays and drops", true in first && false in first)
        assertNotEquals(first, decisions(seed = 43))
    }

    /** `nextDouble()` 永遠是 [0, 1) 的最大值：機率路徑一律不轉發，只剩無條件轉發會送出。 */
    private object NeverWinsTheDraw : Random() {
        override fun nextBits(bitCount: Int): Int = 0
        override fun nextDouble(): Double = Math.nextDown(1.0)
    }

    /**
     * 真實的 [PacketRelayManager] 接一個只計算 broadcastPacket 次數的 delegate。預設網路規模 > 100，
     * 機率路徑的轉發機率是 0.4，門檻以外的決策才看得出來。
     */
    private inner class RelayUnderTest(
        policy: RelayPolicy = RelayPolicy(),
        random: Random,
        private val networkSize: Int = 200
    ) : PacketRelayManagerDelegate {
        private val manager = PacketRelayManager(myPeerID, policy, random).also { it.delegate = this }
        private var broadcasts = 0

        /** 收到一個 TTL 為 [receivedTtl] 的廣播封包時，是否轉發出去。 */
        suspend fun relays(receivedTtl: UByte): Boolean {
            val before = broadcasts
            manager.handlePacketRelay(RoutedPacket(createPacket(route = null).copy(ttl = receivedTtl), otherPeerID))
            return broadcasts > before
        }

        override fun getNetworkSize(): Int = networkSize
        override fun getBroadcastRecipient(): ByteArray = ByteArray(8)
        override fun broadcastPacket(routed: RoutedPacket) { broadcasts++ }
        override fun sendToPeer(peerID: String, routed: RoutedPacket): Boolean = false
    }

    private fun hexStringToPeerBytes(hex: String): ByteArray {
        val result = ByteArray(8)
        var idx = 0
        var out = 0
        while (idx + 1 < hex.length && out < 8) {
            val b = hex.substring(idx, idx + 2).toIntOrNull(16)?.toByte() ?: 0
            result[out++] = b
            idx += 2
        }
        return result
    }
}
