package com.bitchat.android.mesh

import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * How PacketProcessor treats ADMIN_NOTICE (0x31, #137): the Inbox behind the delegate decides the
 * relay, and the senderID — a notice's messageId, not a peer (ADR-0011) — never becomes an actor,
 * a last-seen update or a handled message.
 */
class PacketProcessorAdminNoticeTest {
    private val processors = mutableListOf<PacketProcessor>()

    @After
    fun tearDown() {
        processors.forEach(PacketProcessor::shutdown)
    }

    @Test
    fun `an Admin Notice the handler accepts is relayed`() = runBlocking {
        val delegate = RecordingDelegate(acceptAdminNotice = true)
        val processor = processor(delegate)

        processor.processPacket(adminNotice(MESSAGE_ID_1))

        awaitUntil { delegate.relayed.size == 1 }
        assertEquals(listOf(MESSAGE_ID_1), delegate.adminNotices)
    }

    @Test
    fun `an Admin Notice the handler refuses is not relayed`() = runBlocking {
        val delegate = RecordingDelegate(acceptAdminNotice = false)
        val processor = processor(delegate)

        processor.processPacket(adminNotice(MESSAGE_ID_1))

        awaitUntil { delegate.adminNotices.size == 1 }
        delay(250)
        assertTrue(delegate.relayed.isEmpty())
    }

    @Test
    fun `an accepted Admin Notice updates no peer's last seen and is not handled as a message`() = runBlocking {
        val delegate = RecordingDelegate(acceptAdminNotice = true)
        val processor = processor(delegate)

        processor.processPacket(adminNotice(MESSAGE_ID_1))

        awaitUntil { delegate.relayed.size == 1 }
        assertTrue(delegate.lastSeen.isEmpty())
        assertEquals(0, delegate.messagesHandled)
    }

    @Test
    fun `Admin Notices from many messageIds leave one actor, not one per messageId`() = runBlocking {
        val delegate = RecordingDelegate(acceptAdminNotice = true)
        val processor = processor(delegate)

        repeat(20) { i -> processor.processPacket(adminNotice("00000000000000%02x".format(i + 1))) }
        processor.processPacket(announce(PEER_ID))

        awaitUntil { delegate.adminNotices.size == 20 && delegate.lastSeen.isNotEmpty() }
        assertEquals(2, processor.activeActorCount()) // the Admin Notices' one, and the peer's
        assertEquals(listOf(PEER_ID), delegate.lastSeen)
    }

    @Test
    fun `fragments of an Admin Notice share its actor and the reassembled notice reaches the handler`() = runBlocking {
        val delegate = RecordingDelegate(acceptAdminNotice = true)
        val processor = processor(delegate)
        val large = adminNotice(MESSAGE_ID_2, payload = ByteArray(600) { (it % 251).toByte() }).packet
        val fragments = FragmentManager().createFragments(large)
        assertTrue(fragments.size > 1)

        fragments.forEach { processor.processPacket(RoutedPacket(it, MESSAGE_ID_2, "direct-link")) }

        awaitUntil { delegate.adminNotices == listOf(MESSAGE_ID_2) }
        assertEquals(1, processor.activeActorCount())
        assertTrue(delegate.lastSeen.isEmpty())
    }

    @Test
    fun `the relayed copy is the normalized packet, whatever a sender added to it`() = runBlocking {
        val delegate = RecordingDelegate(acceptAdminNotice = true)
        val processor = processor(delegate)
        val normalized = adminNotice(MESSAGE_ID_1, ttl = 6u).packet
        val embellished = normalized.copy(
            version = 2u,
            recipientID = MY_PEER_ID.hexToBytes(),
            signature = ByteArray(64) { 0x5A },
            route = listOf(MY_PEER_ID.hexToBytes(), PEER_ID.hexToBytes()),
            severity = 3u
        )

        processor.processPacket(RoutedPacket(embellished, MESSAGE_ID_1, "direct-link"))

        awaitUntil { delegate.relayed.size == 1 }
        val relayed = delegate.relayed.single()
        assertEquals(1, relayed.version.toInt())
        assertNull(relayed.recipientID)
        assertNull(relayed.signature)
        assertNull(relayed.route)
        assertNull(relayed.severity)
        assertEquals(5, relayed.ttl.toInt())
        assertArrayEquals(
            normalized.copy(ttl = 5u).toBinaryData(padding = false),
            relayed.toBinaryData(padding = false)
        )
    }

    private suspend fun awaitUntil(condition: () -> Boolean) {
        withTimeout(2_000) {
            while (!condition()) delay(10)
        }
    }

    private fun processor(delegate: RecordingDelegate): PacketProcessor =
        PacketProcessor(MY_PEER_ID).also {
            it.delegate = delegate
            processors += it
        }

    /** A 0x31 packet as the BLE layer hands it over: its peerID is parsed from the senderID. */
    private fun adminNotice(
        messageId: String,
        payload: ByteArray = ByteArray(120) { 0x42 },
        ttl: UByte = 6u
    ): RoutedPacket {
        val packet = BitchatPacket(
            version = 1u,
            type = MessageType.ADMIN_NOTICE.value,
            senderID = messageId.hexToBytes(),
            recipientID = null,
            timestamp = 1_792_627_200_000uL,
            payload = payload,
            ttl = ttl
        )
        return RoutedPacket(packet, messageId, "direct-link")
    }

    private fun announce(peerID: String): RoutedPacket {
        val packet = BitchatPacket(
            version = 1u,
            type = MessageType.ANNOUNCE.value,
            senderID = peerID.hexToBytes(),
            recipientID = SpecialRecipients.BROADCAST,
            timestamp = System.currentTimeMillis().toULong(),
            payload = byteArrayOf(0x01),
            ttl = 7u
        )
        return RoutedPacket(packet, peerID, "direct-link")
    }

    private class RecordingDelegate(private val acceptAdminNotice: Boolean) : PacketProcessorDelegate {
        private val fragments = FragmentManager()
        val adminNotices = CopyOnWriteArrayList<String>()
        val lastSeen = CopyOnWriteArrayList<String>()
        val relayed = CopyOnWriteArrayList<BitchatPacket>()
        @Volatile var messagesHandled = 0

        override fun validatePacketSecurity(routed: RoutedPacket) = true
        override fun updatePeerLastSeen(peerID: String) {
            lastSeen += peerID
        }
        override fun getPeerNickname(peerID: String): String? = null
        override fun getNetworkSize() = 1
        override fun getBroadcastRecipient(): ByteArray = SpecialRecipients.BROADCAST
        override fun handleNoiseHandshake(routed: RoutedPacket) = true
        override fun handleNoiseEncrypted(routed: RoutedPacket) = true
        override suspend fun handleAnnounce(routed: RoutedPacket) = true
        override fun handleMessage(routed: RoutedPacket) {
            messagesHandled += 1
        }
        override fun handleAdminNotice(routed: RoutedPacket): Boolean {
            adminNotices += routed.packet.senderID.joinToString("") { "%02x".format(it) }
            return acceptAdminNotice
        }
        override fun handleLeave(routed: RoutedPacket) = Unit
        override fun handleFragment(packet: BitchatPacket): BitchatPacket? = fragments.handleFragment(packet)
        override fun handleRequestSync(routed: RoutedPacket) = Unit
        override fun sendAnnouncementToPeer(peerID: String) = Unit
        override fun sendCachedMessages(peerID: String) = Unit
        override fun relayPacket(routed: RoutedPacket) {
            if (routed.packet.type == MessageType.ADMIN_NOTICE.value) relayed += routed.packet
        }
        override fun sendToPeer(peerID: String, routed: RoutedPacket) = false
    }

    private companion object {
        const val MY_PEER_ID = "1111222233334444"
        const val PEER_ID = "aaaabbbbccccdddd"
        const val MESSAGE_ID_1 = "a1b2c3d4e5f60718"
        const val MESSAGE_ID_2 = "0f1e2d3c4b5a6978"

        fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
}
