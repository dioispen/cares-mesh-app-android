package com.bitchat.android.adminnotice

import com.bitchat.android.testsupport.ManualScheduler
import com.bitchat.android.testsupport.RecordingInjector
import com.bitchat.android.testsupport.RecordingSyncSet
import com.bitchat.android.testsupport.TestAdminNotices
import com.bitchat.android.testsupport.TestAdminNotices.V1
import com.bitchat.android.testsupport.TestAdminNotices.V1_EXPIRES_AT
import com.bitchat.android.testsupport.TestAdminNotices.V1_MESSAGE_ID
import com.bitchat.android.testsupport.TestAdminNotices.V2
import com.bitchat.android.testsupport.TestAdminNotices.V2_MESSAGE_ID
import com.bitchat.android.testsupport.TestAdminNotices.V4
import com.bitchat.android.testsupport.TestAdminNotices.VECTOR_ISSUED_AT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Inbox's 加入 sync 集合 (#138, 處理規則 step 10): only once the Administrators' signature is
 * verified, every notice that enters the mesh — heard, or injected by this Gateway — is offered to
 * the running mesh service's sync set with its expiresAt, as the normalized outer packet.
 */
class AdminNoticeSyncTest {

    private var now = VECTOR_ISSUED_AT + 60_000L
    private val scheduler = ManualScheduler()
    private val mesh = RecordingInjector()
    private val sync = RecordingSyncSet()

    private val inbox = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) = Unit
        },
        nowMs = { now },
        injectionScheduler = scheduler,
        injectionDelayMs = { 7_000L }
    )

    private fun advance(ms: Long) {
        now += ms
        scheduler.advance(ms)
    }

    // ── mesh 聽到的 ─────────────────────────────────────────────────────────

    @Test
    fun `a notice heard over the mesh joins the sync set as the normalized packet, until its expiresAt`() {
        inbox.attachSyncSet(sync)

        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 3u).copy(signature = ByteArray(64) { 9 }))

        val (packet, expiresAt) = sync.added.single()
        assertEquals(TestAdminNotices.meshPacket(V1, ttl = 7u), packet)
        assertEquals(V1_EXPIRES_AT, expiresAt)
    }

    @Test
    fun `a targeted notice joins the sync set too, still encrypted`() {
        inbox.attachSyncSet(sync)

        inbox.onMeshPacket(TestAdminNotices.meshPacket(V2))

        val (packet, expiresAt) = sync.added.single()
        assertEquals(TestAdminNotices.meshPacket(V2, ttl = 7u), packet)
        assertEquals(V2_EXPIRES_AT, expiresAt)
    }

    @Test
    fun `a notice that fails verification does not join the sync set`() {
        inbox.attachSyncSet(sync)

        inbox.onMeshPacket(TestAdminNotices.meshPacket(V4))
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, timestamp = VECTOR_ISSUED_AT + 1))
        inbox.onBackendNotice(V4)

        assertTrue(sync.added.isEmpty())
    }

    @Test
    fun `a copy heard again does not join twice`() {
        inbox.attachSyncSet(sync)

        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 6u))
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 2u))

        assertEquals(1, sync.added.size)
    }

    @Test
    fun `a notice accepted within the clock tolerance but past its expiresAt has nothing left to offer`() {
        inbox.attachSyncSet(sync)
        now = V1_EXPIRES_AT + 5 * 60_000L

        assertTrue(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)

        assertTrue(sync.added.isEmpty())
    }

    // ── Gateway 注入的 ──────────────────────────────────────────────────────

    @Test
    fun `a backend notice joins the sync set when this Gateway injects it, not before`() {
        inbox.attachInjector(mesh)
        inbox.attachSyncSet(sync)

        inbox.onBackendNotice(V1)
        assertTrue(sync.added.isEmpty())
        advance(7_000)

        assertEquals(listOf(V1_MESSAGE_ID), sync.messageIds())
        assertEquals(mesh.injected.single(), sync.added.single().first)
    }

    @Test
    fun `a backend notice whose injection is dropped does not join`() {
        mesh.accepts = false
        inbox.attachInjector(mesh)
        inbox.attachSyncSet(sync)

        inbox.onBackendNotice(V1)
        advance(7_000)

        assertTrue(sync.added.isEmpty())
    }

    @Test
    fun `a backend notice heard over the mesh before its injection joins then`() {
        inbox.attachInjector(mesh)
        inbox.attachSyncSet(sync)
        inbox.onBackendNotice(V1)
        advance(3_000)

        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))
        advance(15_000)

        assertEquals(listOf(V1_MESSAGE_ID), sync.messageIds())
        assertTrue(mesh.injected.isEmpty())
    }

    // ── mesh 服務換新的實例 ──────────────────────────────────────────────────

    @Test
    fun `a sync set attached later is handed the notices already in the mesh`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V2))

        inbox.attachSyncSet(sync)

        assertEquals(listOf(V1_MESSAGE_ID, V2_MESSAGE_ID).sorted(), sync.messageIds().sorted())
        assertEquals(V1_EXPIRES_AT, sync.added.single { it.first.payload.contentEquals(V1) }.second)
    }

    @Test
    fun `a sync set attached later is not handed notices that have expired`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V2))
        now = V2_EXPIRES_AT

        inbox.attachSyncSet(sync)

        assertEquals(listOf(V1_MESSAGE_ID), sync.messageIds())
    }

    @Test
    fun `after the mesh service restarts, its new sync set gets what the stopped one had, and the stopped one nothing more`() {
        val stopped = RecordingSyncSet()
        inbox.attachSyncSet(stopped)
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))
        inbox.detachSyncSet(stopped)

        inbox.onMeshPacket(TestAdminNotices.meshPacket(V2))
        inbox.attachSyncSet(sync)

        assertEquals(listOf(V1_MESSAGE_ID), stopped.messageIds())
        assertEquals(listOf(V1_MESSAGE_ID, V2_MESSAGE_ID).sorted(), sync.messageIds().sorted())
    }

    @Test
    fun `a replaced mesh service stopping late leaves its successor's sync set attached`() {
        val replaced = RecordingSyncSet()
        inbox.attachSyncSet(replaced)
        inbox.attachSyncSet(sync)

        inbox.detachSyncSet(replaced)
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))

        assertEquals(listOf(V1_MESSAGE_ID), sync.messageIds())
        assertTrue(replaced.added.isEmpty())
    }

    @Test
    fun `for a new mesh service the Inbox keeps at most 50 notices, dropping the one expiring first`() {
        val notices = (1..51).map { i ->
            // The second one expires first; the first one stored expires last.
            val expiresAt = if (i == 1) VECTOR_ISSUED_AT + 20 * HOUR else VECTOR_ISSUED_AT + HOUR + i
            TestAdminNotices.signed(messageId = "%016x".format(i), expiresAt = expiresAt)
        }
        notices.forEach { inbox.onMeshPacket(TestAdminNotices.meshPacket(it)) }

        inbox.attachSyncSet(sync)

        val handed = sync.messageIds()
        assertEquals(50, handed.size)
        assertFalse("%016x".format(2) in handed)
        assertTrue("%016x".format(1) in handed && "%016x".format(51) in handed)
    }

    private companion object {
        const val HOUR = 3_600_000L

        /** V2's expiresAt: two hours after it was issued. */
        const val V2_EXPIRES_AT = 1_792_634_400_000L
    }
}
