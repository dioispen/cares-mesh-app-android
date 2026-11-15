package com.bitchat.android.sync

import com.bitchat.android.model.RequestSyncPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Admin Notice（0x31）納入 gossip sync（#138，docs/ADMIN_NOTICE_V1.md「Gossip sync」）：Inbox 驗過簽章
 * 才交進來，每個 messageId 一份，保留到呼叫端給的 expiresAt。sync 層不解析 payload，所以這裡的
 * payload 只是任意位元組。
 */
@RunWith(RobolectricTestRunner::class)
class GossipSyncManagerAdminNoticeTest {

    private val myPeerID = "0102030405060708"
    private val requester = "c1c2c3c4c5c6c7c8"

    private var now = 1_792_627_260_000L
    private val sent = mutableListOf<Pair<String, BitchatPacket>>()
    /** What SecurityManager's key cache would answer for a senderID. */
    private val cachedAnnouncements = mutableMapOf<String, BitchatPacket>()
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
            nowMs = { now },
            cachedAnnouncementFor = { cachedAnnouncements[it] }
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
    fun `a notice the requester lacks is sent to it alone, unchanged but for the sync ttl`() {
        val notice = adminNotice(NOTICE_A)
        manager.onAdminNoticeSeen(notice, expiresAtMs = now + HOUR)

        manager.handleRequestSync(requester, emptyRequest())

        val (to, packet) = sent.single()
        assertEquals(requester, to)
        assertEquals(notice.copy(ttl = AppConstants.SYNC_TTL_HOPS), packet)
    }

    @Test
    fun `a notice the requester already has is not sent`() {
        val notice = adminNotice(NOTICE_A)
        manager.onAdminNoticeSeen(notice, expiresAtMs = now + HOUR)

        manager.handleRequestSync(requester, requestHaving(notice))

        assertEquals(emptyList<Pair<String, BitchatPacket>>(), sent)
    }

    @Test
    fun `own gcs filter advertises held notices`() {
        val notice = adminNotice(NOTICE_A)
        manager.onAdminNoticeSeen(notice, expiresAtMs = now + HOUR)

        assertTrue(gcsContains(notice))
    }

    // ── 保留到 expiresAt ──────────────────────────────────────────────────────

    @Test
    fun `a notice is no longer sent or advertised once its expiresAt has come`() {
        val notice = adminNotice(NOTICE_A)
        manager.onAdminNoticeSeen(notice, expiresAtMs = now + HOUR)

        now += HOUR
        manager.handleRequestSync(requester, emptyRequest())

        assertEquals(emptyList<Pair<String, BitchatPacket>>(), sent)
        assertFalse(gcsContains(notice))
    }

    @Test
    fun `the periodic cleanup drops expired notices and keeps the rest`() {
        manager.onAdminNoticeSeen(adminNotice(NOTICE_A), expiresAtMs = now + HOUR)
        manager.onAdminNoticeSeen(adminNotice(NOTICE_B), expiresAtMs = now + 2 * HOUR)

        now += HOUR
        manager.pruneExpiredAdminNotices()

        assertEquals(listOf(NOTICE_B), syncedNoticeIds())
    }

    @Test
    fun `a notice handed in already expired is not kept`() {
        val notice = adminNotice(NOTICE_A)
        manager.onAdminNoticeSeen(notice, expiresAtMs = now)

        assertEquals(emptyList<String>(), syncedNoticeIds())
        assertFalse(gcsContains(notice))
    }

    @Test
    fun `one copy is kept per messageId`() {
        manager.onAdminNoticeSeen(adminNotice(NOTICE_A), expiresAtMs = now + HOUR)
        manager.onAdminNoticeSeen(adminNotice(NOTICE_A), expiresAtMs = now + HOUR)

        assertEquals(listOf(NOTICE_A), syncedNoticeIds())
    }

    // ── 上限 50 則 ──────────────────────────────────────────────────────────

    @Test
    fun `past 50 notices the one expiring first is dropped, not the one stored first`() {
        manager.onAdminNoticeSeen(adminNotice(id(1)), expiresAtMs = now + 10 * HOUR)
        for (i in 2..50) manager.onAdminNoticeSeen(adminNotice(id(i)), expiresAtMs = now + 2 * HOUR + i)

        manager.onAdminNoticeSeen(adminNotice(id(51)), expiresAtMs = now + 5 * HOUR)

        val synced = syncedNoticeIds()
        assertEquals(50, synced.size)
        assertFalse(id(2) in synced)
        assertTrue(id(1) in synced && id(51) in synced)
    }

    @Test
    fun `a new notice expiring before all 50 held ones is the one dropped`() {
        for (i in 1..50) manager.onAdminNoticeSeen(adminNotice(id(i)), expiresAtMs = now + 2 * HOUR + i)

        manager.onAdminNoticeSeen(adminNotice(id(51)), expiresAtMs = now + HOUR)

        assertEquals((1..50).map(::id).sorted(), syncedNoticeIds().sorted())
    }

    // ── 沒有 ANNOUNCE ───────────────────────────────────────────────────────

    @Test
    fun `no announcement goes ahead of a notice, even one cached under its senderID`() {
        val notice = adminNotice(NOTICE_A)
        val announcement = staleAnnouncement(NOTICE_A)
        cachedAnnouncements[NOTICE_A] = announcement
        manager.onAdminNoticeSeen(notice, expiresAtMs = now + HOUR)

        manager.handleRequestSync(requester, emptyRequest())

        assertEquals(listOf(MessageType.ADMIN_NOTICE.value), sent.map { it.second.type })
        assertFalse(gcsContains(announcement))
    }

    // ── 只從驗過簽章的入口進來 ───────────────────────────────────────────────

    @Test
    fun `a 0x31 seen as an ordinary public packet is not kept`() {
        manager.onPublicPacketSeen(adminNotice(NOTICE_A))

        assertEquals(emptyList<String>(), syncedNoticeIds())
    }

    // ── 移除 ────────────────────────────────────────────────────────────────

    @Test
    fun `a removed notice is no longer sent or advertised, the others still are`() {
        val removed = adminNotice(NOTICE_A)
        manager.onAdminNoticeSeen(removed, expiresAtMs = now + HOUR)
        manager.onAdminNoticeSeen(adminNotice(NOTICE_B), expiresAtMs = now + HOUR)

        manager.removeAdminNotice(NOTICE_A)

        assertEquals(listOf(NOTICE_B), syncedNoticeIds())
        assertFalse(gcsContains(removed))
    }

    @Test
    fun `clear drops held notices`() {
        manager.onAdminNoticeSeen(adminNotice(NOTICE_A), expiresAtMs = now + HOUR)

        manager.clear()

        assertEquals(emptyList<String>(), syncedNoticeIds())
    }

    /** The messageIds of the notices a requester holding nothing is sent. */
    private fun syncedNoticeIds(): List<String> {
        sent.clear()
        manager.handleRequestSync(requester, emptyRequest())
        return sent.map { it.second }
            .filter { it.type == MessageType.ADMIN_NOTICE.value }
            .map { packet -> packet.senderID.joinToString("") { "%02x".format(it) } }
    }

    private fun gcsContains(packet: BitchatPacket): Boolean {
        val request = RequestSyncPacket.decode(manager.buildGcsPayload())!!
        val sorted = GCSFilter.decodeToSortedSet(request.p, request.m, request.data)
        val v = GCSFilter.h64(PacketIdUtil.computeIdBytes(packet)) % request.m
        return GCSFilter.contains(sorted, if (v == 0L) 1L else v)
    }

    private fun requestHaving(vararg packets: BitchatPacket): RequestSyncPacket {
        val params = GCSFilter.buildFilter(
            packets.map { PacketIdUtil.computeIdBytes(it) },
            SyncDefaults.DEFAULT_FILTER_BYTES,
            FPR
        )
        return RequestSyncPacket(p = params.p, m = params.m, data = params.data)
    }

    private fun emptyRequest(): RequestSyncPacket =
        RequestSyncPacket(p = GCSFilter.deriveP(FPR), m = 1, data = ByteArray(0))

    /** A normalized 0x31 packet: senderID the messageId, timestamp the issuedAt. */
    private fun adminNotice(messageId: String, issuedAt: Long = now - 60_000L) = BitchatPacket(
        version = 1u,
        type = MessageType.ADMIN_NOTICE.value,
        senderID = hex(messageId),
        recipientID = null,
        timestamp = issuedAt.toULong(),
        payload = ByteArray(120) { (it * 7).toByte() } + hex(messageId),
        signature = null,
        ttl = AppConstants.MESSAGE_TTL_HOPS
    )

    /** An ANNOUNCE older than the peer timeout, the kind a held Health Report's sender gets sent with. */
    private fun staleAnnouncement(sender: String) = BitchatPacket(
        type = MessageType.ANNOUNCE.value,
        senderID = hex(sender),
        timestamp = (now - 30 * 60_000L).toULong(),
        payload = byteArrayOf(1, 2, 3),
        ttl = AppConstants.MESSAGE_TTL_HOPS
    )

    private fun id(i: Int): String = "%016x".format(i)

    private fun hex(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private companion object {
        const val NOTICE_A = "a1b2c3d4e5f60718"
        const val NOTICE_B = "0f1e2d3c4b5a6978"
        const val HOUR = 3_600_000L

        // ConfigProvider.gcsTargetFpr() 回傳的是 0..1 的比例，不是百分比
        const val FPR = 0.01
    }
}
