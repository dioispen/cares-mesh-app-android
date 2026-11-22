package com.bitchat.android.adminnotice

import com.bitchat.android.mesh.FragmentManager
import com.bitchat.android.mesh.PacketProcessor
import com.bitchat.android.mesh.PacketProcessorDelegate
import com.bitchat.android.mesh.PeerManager
import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.testsupport.ManualScheduler
import com.bitchat.android.testsupport.TestAdminNotices
import com.bitchat.android.testsupport.TestAdminNotices.V1
import com.bitchat.android.testsupport.TestAdminNotices.V2
import com.bitchat.android.testsupport.TestAdminNotices.V3
import com.bitchat.android.testsupport.TestAdminNotices.V4
import com.bitchat.android.testsupport.TestAdminNotices.V5
import com.bitchat.android.testsupport.TestAdminNotices.V5_MESSAGE_ID
import com.bitchat.android.testsupport.TestAdminNotices.VECTOR_ISSUED_AT
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A relay's whole receive path for 0x31 (#137): PacketProcessor hands every packet to the real
 * Inbox, whole or reassembled from its fragments, relays only what it accepts, and the peer list
 * and packet actors stay as they were. The processor's actors run on [actors]: a test runs them
 * to idle, then looks at what they did.
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
    /** Every packet this relay passed on, in order. */
    private val relayed = CopyOnWriteArrayList<BitchatPacket>()
    private val handled = CopyOnWriteArrayList<String>()
    private val actors = StandardTestDispatcher()

    /** The sending side's fragmenter, and this relay's reassembly. */
    private val sender = FragmentManager()
    private val reassembly = FragmentManager()
    private val processor = PacketProcessor(MY_PEER_ID, actors).also { it.delegate = RelayDelegate() }

    @After
    fun tearDown() {
        processor.shutdown()
        peers.shutdown()
        sender.shutdown()
        reassembly.shutdown()
    }

    @Test
    fun `many notices, a forgery and repeats change no peer, leave one actor, and only verified copies are relayed, once each`() {
        val others = (1..5).map { TestAdminNotices.signed(messageId = "00000000000000%02x".format(it)) }
        val heard = listOf(V4, V1, V1, V2, V3) + others + others

        hear(heard.map { TestAdminNotices.meshPacket(it) })

        actors.scheduler.advanceUntilIdle()
        assertEquals(heard.size, handled.size)
        // processPacket hands packets to the actor from separate coroutines: arrival order is not kept.
        val othersIds = (1..5).map { "00000000000000%02x".format(it) }
        val expected = listOf(TestAdminNotices.V1_MESSAGE_ID, TestAdminNotices.V2_MESSAGE_ID, TestAdminNotices.V3_MESSAGE_ID) + othersIds
        assertEquals(expected.sorted(), relayed.map { it.senderID.toHex() }.sorted())
        assertEquals((listOf(TestAdminNotices.V1_MESSAGE_ID) + othersIds).sorted(), shown.sorted())
        assertEquals(listOf(PEER_ID), peers.getActivePeerIDs())
        assertEquals(1, processor.activeActorCount())
    }

    @Test
    fun `a forged notice split into fragments is relayed neither fragment by fragment nor reassembled`() {
        val forged = V5.also { it[FORGED_BYTE] = (it[FORGED_BYTE].toInt() xor 0x01).toByte() }

        hear(fragmentsOf(TestAdminNotices.meshPacket(forged)))

        actors.scheduler.advanceUntilIdle()
        assertEquals("the Inbox saw the reassembled forgery", listOf(V5_MESSAGE_ID), handled)
        assertEquals(emptyList<BitchatPacket>(), relayed)
        assertEquals(emptyList<String>(), shown)
    }

    @Test
    fun `V5 split into fragments is relayed once, as the reassembled normalized notice, one hop down`() {
        // The fragments carry whatever their sender put on the outer packet: a recipient and a route.
        val embellished = TestAdminNotices.meshPacket(V5, ttl = 6u).copy(
            version = 2u,
            recipientID = OTHER_PEER_ID.hexToBytes(),
            route = listOf(PEER_ID.hexToBytes(), OTHER_PEER_ID.hexToBytes())
        )

        hear(fragmentsOf(embellished))

        actors.scheduler.advanceUntilIdle()
        assertEquals(listOf(V5_MESSAGE_ID), handled)
        val passedOn = relayed.single()
        assertEquals(MessageType.ADMIN_NOTICE.value, passedOn.type)
        assertArrayEquals(
            TestAdminNotices.meshPacket(V5, ttl = 5u).toBinaryData(padding = false),
            passedOn.toBinaryData(padding = false)
        )
    }

    @Test
    fun `V5 heard again in another set of fragments is not relayed a second time`() {
        // Two neighbours each fragmented it: different fragment IDs, the same notice.
        hear(fragmentsOf(TestAdminNotices.meshPacket(V5, ttl = 6u)))
        hear(fragmentsOf(TestAdminNotices.meshPacket(V5, ttl = 4u)))

        actors.scheduler.advanceUntilIdle()
        assertEquals(listOf(V5_MESSAGE_ID, V5_MESSAGE_ID), handled)
        assertEquals(listOf(5), relayed.map { it.ttl.toInt() })
    }

    /** [packets] heard over one BLE link, in order, as the BLE layer hands them over. */
    private fun hear(packets: List<BitchatPacket>) = packets.forEach { packet ->
        processor.processPacket(RoutedPacket(packet, packet.senderID.toHex(), "AA:00:00:00:00:01"))
    }

    /** [packet] as the sending side's transport puts it on the air: more than one fragment. */
    private fun fragmentsOf(packet: BitchatPacket): List<BitchatPacket> =
        sender.createFragments(packet).also { assertTrue("${it.size} fragments", it.size > 1) }

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
        override fun handleFragment(packet: BitchatPacket): BitchatPacket? = reassembly.handleFragment(packet)
        override fun handleRequestSync(routed: RoutedPacket) = Unit
        override fun sendAnnouncementToPeer(peerID: String) = Unit
        override fun sendCachedMessages(peerID: String) = Unit
        override fun relayPacket(routed: RoutedPacket) {
            relayed += routed.packet
        }
        override fun sendToPeer(peerID: String, routed: RoutedPacket) = false
    }

    private companion object {
        const val MY_PEER_ID = "1111222233334444"
        const val PEER_ID = "aaaabbbbccccdddd"
        const val OTHER_PEER_ID = "5555666677778888"

        /** A byte in V5's recipient entries: flipping it leaves the layout valid and breaks the signature. */
        const val FORGED_BYTE = 200

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
        fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
}
