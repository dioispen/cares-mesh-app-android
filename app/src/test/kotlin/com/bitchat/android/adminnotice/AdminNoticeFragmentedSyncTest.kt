package com.bitchat.android.adminnotice

import com.bitchat.android.adminnotice.TestAdminNotices.V5
import com.bitchat.android.adminnotice.TestAdminNotices.V5_MESSAGE_ID
import com.bitchat.android.adminnotice.TestAdminNotices.VECTOR_ISSUED_AT
import com.bitchat.android.mesh.BLEPacketPaddingPolicy
import com.bitchat.android.mesh.FragmentManager
import com.bitchat.android.mesh.FragmentingPacketSender
import com.bitchat.android.mesh.PacketProcessor
import com.bitchat.android.mesh.PacketProcessorDelegate
import com.bitchat.android.model.FragmentPayload
import com.bitchat.android.model.RequestSyncPacket
import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.sync.GCSFilter
import com.bitchat.android.sync.GossipSyncManager
import com.bitchat.android.sync.SyncDefaults
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

/**
 * 實作前待驗證 1 (#138): an Admin Notice over 512 bytes makes it through gossip sync whole. A relay
 * that heard V5 answers a late arrival's REQUEST_SYNC; the reply goes out through the transports'
 * FragmentingPacketSender, crosses "the air" as encoded frames, and the late arrival's
 * PacketProcessor reassembles it and hands it to its Inbox, which verifies the Administrators'
 * signature. The late arrival then holds it in its own sync set, to pass on.
 */
@RunWith(RobolectricTestRunner::class)
class AdminNoticeFragmentedSyncTest {

    private val now = VECTOR_ISSUED_AT + 60_000L
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val fragmentManagers = mutableListOf<FragmentManager>()

    /** Encoded frames the relay's sync reply put on the air, in order. */
    private val onAir = CopyOnWriteArrayList<ByteArray>()

    /** What the relay's gossip sync asked the transport to send, before fragmenting. */
    private val replies = CopyOnWriteArrayList<BitchatPacket>()

    private val relaySync = gossipSync(RELAY).also { sync ->
        val sender = FragmentingPacketSender(scope, fragmentManager(), "relay", interFragmentDelayMs = 0)
        sync.delegate = object : GossipSyncManager.Delegate {
            override fun sendPacket(packet: BitchatPacket) = Unit
            override fun sendPacketToPeer(peerID: String, packet: BitchatPacket) {
                replies += packet
                // As BluetoothPacketBroadcaster.sendPacketToPeer does it: fragment, then encode each.
                sender.send(RoutedPacket(packet), "sync reply to $peerID") { single ->
                    onAir += single.packet.toBinaryData(padding = BLEPacketPaddingPolicy.shouldPadForBLE(single.packet.type))!!
                    true
                }
            }
            override fun signPacketForBroadcast(packet: BitchatPacket) = packet
        }
    }
    private val relayInbox = inbox().also { it.attachSyncSet(syncSetOf(relaySync)) }

    private val lateSync = gossipSync(LATE)
    private val lateInbox = inbox().also { it.attachSyncSet(syncSetOf(lateSync)) }
    private val lateOutcomes = CopyOnWriteArrayList<AdminNoticeOutcome>()
    private val lateProcessor = PacketProcessor(LATE).also { it.delegate = LateArrival(fragmentManager()) }

    @After
    fun tearDown() {
        lateProcessor.shutdown()
        fragmentManagers.forEach(FragmentManager::shutdown)
        scope.cancel()
    }

    @Test
    fun `V5 sent as a sync reply is fragmented, reassembled by the late arrival and accepted by its Inbox`() = runBlocking {
        assertTrue(relayInbox.onMeshPacket(TestAdminNotices.meshPacket(V5)).relay)

        relaySync.handleRequestSync(LATE, RequestSyncPacket.decode(lateSync.buildGcsPayload())!!)

        val reply = replies.single()
        assertEquals(MessageType.ADMIN_NOTICE.value, reply.type)
        assertEquals(683, reply.toBinaryData(padding = false)!!.size)
        withTimeout(5_000) { while (onAir.size < 2) delay(10) }
        delay(100)
        val fragments = onAir.map { BitchatPacket.fromBinaryData(it)!! }
        assertEquals(2, fragments.size)
        fragments.forEach { fragment ->
            assertEquals(MessageType.FRAGMENT.value, fragment.type)
            assertEquals(MessageType.ADMIN_NOTICE.value, FragmentPayload.decode(fragment.payload)!!.originalType)
            assertEquals(0, fragment.ttl.toInt())
        }

        fragments.forEach { lateProcessor.processPacket(RoutedPacket(it, it.senderID.toHex(), "relay-link")) }

        withTimeout(5_000) { while (lateOutcomes.isEmpty()) delay(10) }
        val accepted = lateOutcomes.single() as AdminNoticeOutcome.Accepted
        assertEquals(V5_MESSAGE_ID, accepted.payload.messageId)
        assertArrayEquals(V5, accepted.payload.wire)
        assertEquals(5, (accepted.payload.body as AdminNoticeBody.Targeted).recipients.size)
    }

    @Test
    fun `the late arrival then offers V5 to the next one through its own sync set`() = runBlocking {
        relayInbox.onMeshPacket(TestAdminNotices.meshPacket(V5))
        relaySync.handleRequestSync(LATE, emptyRequest())
        withTimeout(5_000) { while (onAir.size < 2) delay(10) }
        onAir.map { BitchatPacket.fromBinaryData(it)!! }
            .forEach { lateProcessor.processPacket(RoutedPacket(it, it.senderID.toHex(), "relay-link")) }
        withTimeout(5_000) { while (lateOutcomes.isEmpty()) delay(10) }

        val passedOn = CopyOnWriteArrayList<BitchatPacket>()
        lateSync.delegate = object : GossipSyncManager.Delegate {
            override fun sendPacket(packet: BitchatPacket) = Unit
            override fun sendPacketToPeer(peerID: String, packet: BitchatPacket) {
                passedOn += packet
            }
            override fun signPacketForBroadcast(packet: BitchatPacket) = packet
        }
        lateSync.handleRequestSync(NEXT, emptyRequest())

        assertArrayEquals(V5, passedOn.single().payload)
    }

    /** The late arrival's mesh service, as far as an Admin Notice goes. */
    private inner class LateArrival(private val fragments: FragmentManager) : PacketProcessorDelegate {
        override fun validatePacketSecurity(routed: RoutedPacket) = true
        override fun updatePeerLastSeen(peerID: String) = Unit
        override fun getPeerNickname(peerID: String): String? = null
        override fun getNetworkSize() = 1
        override fun getBroadcastRecipient(): ByteArray = SpecialRecipients.BROADCAST
        override fun handleNoiseHandshake(routed: RoutedPacket) = false
        override fun handleNoiseEncrypted(routed: RoutedPacket) = false
        override suspend fun handleAnnounce(routed: RoutedPacket) = false
        override fun handleMessage(routed: RoutedPacket) = Unit
        override fun handleAdminNotice(routed: RoutedPacket): Boolean =
            lateInbox.onMeshPacket(routed.packet).also { lateOutcomes += it }.relay
        override fun handleLeave(routed: RoutedPacket) = Unit
        override fun handleFragment(packet: BitchatPacket): BitchatPacket? = fragments.handleFragment(packet)
        override fun handleRequestSync(routed: RoutedPacket) = Unit
        override fun sendAnnouncementToPeer(peerID: String) = Unit
        override fun sendCachedMessages(peerID: String) = Unit
        override fun relayPacket(routed: RoutedPacket) = Unit
        override fun sendToPeer(peerID: String, routed: RoutedPacket) = false
    }

    private fun inbox() = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) = Unit
        },
        nowMs = { now },
        injectionScheduler = ManualScheduler()
    )

    private fun gossipSync(peerID: String) = GossipSyncManager(
        myPeerID = peerID,
        scope = scope,
        configProvider = object : GossipSyncManager.ConfigProvider {
            override fun seenCapacity(): Int = 500
            override fun gcsMaxBytes(): Int = SyncDefaults.DEFAULT_FILTER_BYTES
            override fun gcsTargetFpr(): Double = FPR
        },
        nowMs = { now }
    )

    /** The port a mesh service attaches for its gossip sync, as BluetoothMeshService does. */
    private fun syncSetOf(sync: GossipSyncManager) = object : AdminNoticeSyncSet {
        override fun add(packet: BitchatPacket, expiresAtMs: Long) = sync.onAdminNoticeSeen(packet, expiresAtMs)
        override fun remove(messageId: String) = sync.removeAdminNotice(messageId)
    }

    private fun fragmentManager() = FragmentManager().also { fragmentManagers += it }

    private fun emptyRequest() = RequestSyncPacket(p = GCSFilter.deriveP(FPR), m = 1, data = ByteArray(0))

    private companion object {
        const val RELAY = "b1b2b3b4b5b6b7b8"
        const val LATE = "a1a2a3a4a5a6a7a8"
        const val NEXT = "c1c2c3c4c5c6c7c8"
        const val FPR = 0.01

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    }
}
