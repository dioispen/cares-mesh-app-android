package com.bitchat.android.sync

import com.bitchat.android.model.RequestSyncPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Health Report 納入 anti-entropy 同步（#91）：每個發送者只保留最新一份，
 * 保存期限依 Health Report 自己的 timestamp，與 ANNOUNCE 脫鉤。
 */
@RunWith(RobolectricTestRunner::class)
class GossipSyncManagerHealthReportTest {

    private val myPeerID = "0102030405060708"
    private val reporterA = "a1a2a3a4a5a6a7a8"
    private val reporterB = "b1b2b3b4b5b6b7b8"
    private val requester = "c1c2c3c4c5c6c7c8"

    private var now = 1_800_000_000_000L
    private val sent = mutableListOf<Pair<String, BitchatPacket>>()
    private lateinit var scope: CoroutineScope
    private lateinit var manager: GossipSyncManager

    @Before
    fun setup() {
        scope = CoroutineScope(SupervisorJob())
        manager = GossipSyncManager(
            myPeerID = myPeerID,
            scope = scope,
            configProvider = object : GossipSyncManager.ConfigProvider {
                override fun seenCapacity(): Int = 100
                override fun gcsMaxBytes(): Int = SyncDefaults.DEFAULT_FILTER_BYTES
                override fun gcsTargetFpr(): Double = FPR
            },
            nowMs = { now }
        )
        manager.delegate = object : GossipSyncManager.Delegate {
            override fun sendPacket(packet: BitchatPacket) {}
            override fun sendPacketToPeer(peerID: String, packet: BitchatPacket) {
                sent += peerID to packet
            }
            override fun signPacketForBroadcast(packet: BitchatPacket): BitchatPacket = packet
        }
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    @Test
    fun `keeps only the newest health report per sender when fed in order`() {
        val older = healthReport(reporterA, now - 10_000, status = 1)
        val newer = healthReport(reporterA, now - 5_000, status = 2)

        manager.onPublicPacketSeen(older)
        manager.onPublicPacketSeen(newer)

        assertEquals(listOf(newer), syncedHealthReports())
    }

    @Test
    fun `keeps only the newest health report per sender when fed out of order`() {
        val older = healthReport(reporterA, now - 10_000, status = 1)
        val newer = healthReport(reporterA, now - 5_000, status = 2)

        manager.onPublicPacketSeen(newer)
        manager.onPublicPacketSeen(older)

        assertEquals(listOf(newer), syncedHealthReports())
    }

    @Test
    fun `keeps one health report for each sender`() {
        val fromA = healthReport(reporterA, now - 10_000)
        val fromB = healthReport(reporterB, now - 5_000)

        manager.onPublicPacketSeen(fromA)
        manager.onPublicPacketSeen(fromB)

        assertEquals(setOf(fromA, fromB), syncedHealthReports().toSet())
    }

    @Test
    fun `does not resend a health report the requester already has`() {
        val report = healthReport(reporterA, now - 10_000)
        manager.onPublicPacketSeen(report)

        manager.handleRequestSync(requester, requestHaving(report))

        assertTrue(sent.none { it.second.type == MessageType.HEALTH_REPORT.value })
    }

    @Test
    fun `resends the original packet to the requester only, with sync ttl`() {
        val report = healthReport(reporterA, now - 10_000).copy(signature = ByteArray(64) { 7 })
        manager.onPublicPacketSeen(report)

        manager.handleRequestSync(requester, emptyRequest())

        val (to, packet) = sent.single { it.second.type == MessageType.HEALTH_REPORT.value }
        assertEquals(requester, to)
        assertEquals(AppConstants.SYNC_TTL_HOPS, packet.ttl)
        assertEquals(report.copy(ttl = AppConstants.SYNC_TTL_HOPS), packet)
        assertTrue(packet.signature!!.contentEquals(report.signature!!))
    }

    @Test
    fun `own gcs filter advertises stored health reports`() {
        val report = healthReport(reporterA, now - 10_000)
        manager.onPublicPacketSeen(report)

        val request = RequestSyncPacket.decode(manager.buildGcsPayload())!!
        val sorted = GCSFilter.decodeToSortedSet(request.p, request.m, request.data)
        val v = GCSFilter.h64(PacketIdUtil.computeIdBytes(report)) % request.m

        assertTrue(GCSFilter.contains(sorted, if (v == 0L) 1L else v))
    }

    @Test
    fun `ignores health reports addressed to a specific peer`() {
        manager.onPublicPacketSeen(healthReport(reporterA, now - 10_000, recipient = hex(requester)))

        assertEquals(emptyList<BitchatPacket>(), syncedHealthReports())
    }

    @Test
    fun `accepts health reports with the explicit broadcast recipient`() {
        val report = healthReport(reporterA, now - 10_000, recipient = SpecialRecipients.BROADCAST)
        manager.onPublicPacketSeen(report)

        assertEquals(listOf(report), syncedHealthReports())
    }

    @Test
    fun `health report survives removal of the sender's announcement`() {
        val report = healthReport(reporterA, now - 10_000)
        manager.onPublicPacketSeen(announce(reporterA, now - 10_000))
        manager.onPublicPacketSeen(report)

        manager.removeAnnouncementForPeer(reporterA)

        assertEquals(listOf(report), syncedHealthReports())
    }

    @Test
    fun `health report survives pruning of stale announcements`() {
        val report = healthReport(reporterA, now - 10_000)
        manager.onPublicPacketSeen(announce(reporterA, now - 10_000))
        manager.onPublicPacketSeen(report)

        now += AppConstants.Mesh.STALE_PEER_TIMEOUT_MS + 1
        manager.pruneStaleAnnouncements()

        assertEquals(listOf(report), syncedHealthReports())
        assertTrue(sent.none { it.second.type == MessageType.ANNOUNCE.value })
    }

    @Test
    fun `health report is dropped once older than the retention period`() {
        manager.onPublicPacketSeen(healthReport(reporterA, now - 10_000))
        val fresh = healthReport(reporterB, now)

        now += AppConstants.Sync.HEALTH_REPORT_RETENTION_MS - 5_000
        manager.onPublicPacketSeen(fresh)
        manager.pruneExpiredHealthReports()

        assertEquals(listOf(fresh), syncedHealthReports())
    }

    @Test
    fun `ignores a health report already older than the retention period`() {
        manager.onPublicPacketSeen(
            healthReport(reporterA, now - AppConstants.Sync.HEALTH_REPORT_RETENTION_MS - 1)
        )

        assertEquals(emptyList<BitchatPacket>(), syncedHealthReports())
    }

    @Test
    fun `clear drops stored health reports`() {
        manager.onPublicPacketSeen(healthReport(reporterA, now - 10_000))

        manager.clear()

        assertEquals(emptyList<BitchatPacket>(), syncedHealthReports())
    }

    private fun syncedHealthReports(): List<BitchatPacket> {
        sent.clear()
        manager.handleRequestSync(requester, emptyRequest())
        return sent.map { it.second }
            .filter { it.type == MessageType.HEALTH_REPORT.value }
            .map { it.copy(ttl = HEALTH_REPORT_TTL) }
    }

    private fun emptyRequest(): RequestSyncPacket =
        RequestSyncPacket(p = GCSFilter.deriveP(FPR), m = 1, data = ByteArray(0))

    private fun requestHaving(vararg packets: BitchatPacket): RequestSyncPacket {
        val params = GCSFilter.buildFilter(
            packets.map { PacketIdUtil.computeIdBytes(it) },
            SyncDefaults.DEFAULT_FILTER_BYTES,
            FPR
        )
        return RequestSyncPacket(p = params.p, m = params.m, data = params.data)
    }

    private fun healthReport(
        sender: String,
        timestamp: Long,
        status: Int = 1,
        recipient: ByteArray? = null
    ) = BitchatPacket(
        type = MessageType.HEALTH_REPORT.value,
        senderID = hex(sender),
        recipientID = recipient,
        timestamp = timestamp.toULong(),
        payload = byteArrayOf(0x30, 1, status.toByte()),
        ttl = HEALTH_REPORT_TTL
    )

    private fun announce(sender: String, timestamp: Long) = BitchatPacket(
        type = MessageType.ANNOUNCE.value,
        senderID = hex(sender),
        timestamp = timestamp.toULong(),
        payload = byteArrayOf(1, 2, 3),
        ttl = 7u
    )

    private fun hex(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private companion object {
        // 與 BitchatFlutterChannels.sendHealthReportPacket 送出時的 TTL 相同；同步回送會改成 SYNC_TTL_HOPS，
        // 比對前還原回來
        val HEALTH_REPORT_TTL: UByte = 3u

        // ConfigProvider.gcsTargetFpr() 回傳的是 0..1 的比例，不是百分比
        const val FPR = 0.01
    }
}
