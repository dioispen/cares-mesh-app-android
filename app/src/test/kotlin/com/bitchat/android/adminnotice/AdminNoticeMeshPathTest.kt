package com.bitchat.android.adminnotice

import com.bitchat.android.mesh.PacketProcessor
import com.bitchat.android.mesh.PacketProcessorDelegate
import com.bitchat.android.mesh.PeerManager
import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.testsupport.ManualScheduler
import com.bitchat.android.testsupport.TestAdminNotices
import com.bitchat.android.testsupport.TestAdminNotices.V1
import com.bitchat.android.testsupport.TestAdminNotices.V2
import com.bitchat.android.testsupport.TestAdminNotices.V3
import com.bitchat.android.testsupport.TestAdminNotices.V4
import com.bitchat.android.testsupport.TestAdminNotices.VECTOR_ISSUED_AT
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A relay's whole receive path for 0x31 (#137): PacketProcessor hands every packet to the real
 * Inbox, relays what it accepts, and the peer list and packet actors stay as they were. The
 * processor's actors run on [actors]: a test runs them to idle, then looks at what they did.
 */
class AdminNoticeMeshPathTest {
    private val shown = CopyOnWriteArrayList<String>()
    private val inbox = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) {
                shown += notice.messageId
            }
        },
        nowMs = { VECTOR_ISSUED_AT + 60_000L },
        injectionScheduler = ManualScheduler()
    )
    private val peers = PeerManager().also { it.addOrUpdatePeer(PEER_ID, "alice") }
    private val relayed = CopyOnWriteArrayList<String>()
    private val handled = CopyOnWriteArrayList<String>()
    private val actors = StandardTestDispatcher()
    private val processor = PacketProcessor(MY_PEER_ID, actors).also { it.delegate = RelayDelegate() }

    @After
    fun tearDown() {
        processor.shutdown()
        peers.shutdown()
    }

    @Test
    fun `many notices, a forgery and repeats change no peer, leave one actor, and only verified copies are relayed, once each`() {
        val others = (1..5).map { TestAdminNotices.signed(messageId = "00000000000000%02x".format(it)) }
        val heard = listOf(V4, V1, V1, V2, V3) + others + others

        heard.forEach { wire ->
            val packet = TestAdminNotices.meshPacket(wire)
            processor.processPacket(RoutedPacket(packet, packet.senderID.toHex(), "AA:00:00:00:00:01"))
        }

        actors.scheduler.advanceUntilIdle()
        assertEquals(heard.size, handled.size)
        // processPacket hands packets to the actor from separate coroutines: arrival order is not kept.
        val othersIds = (1..5).map { "00000000000000%02x".format(it) }
        val expected = listOf(TestAdminNotices.V1_MESSAGE_ID, TestAdminNotices.V2_MESSAGE_ID, TestAdminNotices.V3_MESSAGE_ID) + othersIds
        assertEquals(expected.sorted(), relayed.sorted())
        assertEquals((listOf(TestAdminNotices.V1_MESSAGE_ID) + othersIds).sorted(), shown.sorted())
        assertEquals(listOf(PEER_ID), peers.getActivePeerIDs())
        assertEquals(1, processor.activeActorCount())
    }

    private inner class RelayDelegate : PacketProcessorDelegate {
        override fun validatePacketSecurity(routed: RoutedPacket) = true
        override fun updatePeerLastSeen(peerID: String) = peers.updatePeerLastSeen(peerID)
        override fun getPeerNickname(peerID: String): String? = peers.getPeerNickname(peerID)
        override fun getNetworkSize() = peers.getActivePeerCount()
        override fun getBroadcastRecipient(): ByteArray = SpecialRecipients.BROADCAST
        override fun handleNoiseHandshake(routed: RoutedPacket) = false
        override fun handleNoiseEncrypted(routed: RoutedPacket) = false
        override suspend fun handleAnnounce(routed: RoutedPacket) = false
        override fun handleMessage(routed: RoutedPacket) = Unit
        override fun handleAdminNotice(routed: RoutedPacket): Boolean =
            inbox.onMeshPacket(routed.packet).relay.also { handled += routed.packet.senderID.toHex() }
        override fun handleLeave(routed: RoutedPacket) = Unit
        override fun handleFragment(packet: BitchatPacket): BitchatPacket? = null
        override fun handleRequestSync(routed: RoutedPacket) = Unit
        override fun sendAnnouncementToPeer(peerID: String) = Unit
        override fun sendCachedMessages(peerID: String) = Unit
        override fun relayPacket(routed: RoutedPacket) {
            relayed += routed.packet.senderID.toHex()
        }
        override fun sendToPeer(peerID: String, routed: RoutedPacket) = false
    }

    private companion object {
        const val MY_PEER_ID = "1111222233334444"
        const val PEER_ID = "aaaabbbbccccdddd"

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    }
}
