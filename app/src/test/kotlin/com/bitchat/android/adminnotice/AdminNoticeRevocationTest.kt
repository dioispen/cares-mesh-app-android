package com.bitchat.android.adminnotice

import com.bitchat.android.testsupport.FakeRecipientKey
import com.bitchat.android.testsupport.ManualScheduler
import com.bitchat.android.testsupport.RecordingInjector
import com.bitchat.android.testsupport.RecordingSyncSet
import com.bitchat.android.testsupport.TestAdminNotices
import com.bitchat.android.testsupport.TestAdminNotices.RECIPIENT_1_PRIVATE_HEX
import com.bitchat.android.testsupport.TestAdminNotices.RECIPIENT_2_PRIVATE_HEX
import com.bitchat.android.testsupport.TestAdminNotices.V1
import com.bitchat.android.testsupport.TestAdminNotices.V1_MESSAGE_ID
import com.bitchat.android.testsupport.TestAdminNotices.V2
import com.bitchat.android.testsupport.TestAdminNotices.V2_EXPIRES_AT
import com.bitchat.android.testsupport.TestAdminNotices.V2_MESSAGE_ID
import com.bitchat.android.testsupport.TestAdminNotices.V3
import com.bitchat.android.testsupport.TestAdminNotices.V3_MESSAGE_ID
import com.bitchat.android.testsupport.TestAdminNotices.VECTOR_ISSUED_AT
import com.bitchat.android.util.toHexString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 撤回與取代（#139，docs/ADMIN_NOTICE_V1.md「處理規則」第 7、9 步）：附錄的 V1 與 V3（V3 純撤回 V1）
 * 以兩種順序、從兩個來源交給 Inbox，觀察呈現 port、sync 集合與注入出口收到什麼。
 */
class AdminNoticeRevocationTest {

    /** Ten minutes after V3 was issued, so both vectors are valid. */
    private var now = V3_ISSUED_AT + 10 * 60_000L
    private val presenter = RecordingPresenter()
    private val scheduler = ManualScheduler()
    private val mesh = RecordingInjector()
    private val sync = RecordingSyncSet()

    private val inbox = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = presenter,
        nowMs = { now },
        injectionScheduler = scheduler,
        injectionDelayMs = { 7_000L }
    ).apply {
        attachInjector(mesh)
        attachSyncSet(sync)
    }

    // ── 先收到 V1 再收到 V3 ──────────────────────────────────────────────────

    @Test
    fun `V1 then V3 over the mesh - V1 is withdrawn and leaves the sync set`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))

        val revoke = inbox.onMeshPacket(TestAdminNotices.meshPacket(V3))

        assertTrue("the revoke itself is relayed", revoke.relay)
        assertEquals(listOf("present $V1_MESSAGE_ID", "withdraw $V1_MESSAGE_ID"), presenter.events)
        assertEquals(listOf(V1_MESSAGE_ID), sync.removed)
        assertEquals("V3 joins the sync set", listOf(V1_MESSAGE_ID, V3_MESSAGE_ID), sync.messageIds())
    }

    @Test
    fun `V1 then V3 from the backend - V1 is withdrawn and this Gateway no longer injects it`() {
        inbox.onBackendNotice(V1)
        advance(3_000)

        inbox.onBackendNotice(V3)
        advance(15_000)

        assertEquals(listOf("present $V1_MESSAGE_ID", "withdraw $V1_MESSAGE_ID"), presenter.events)
        assertEquals(listOf(V3_MESSAGE_ID), mesh.injectedIds())
        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED), inbox.onBackendNotice(V1))
    }

    @Test
    fun `V1 then V3 - V1 heard again is no longer relayed`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 6u))
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V3))

        val again = inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 3u))

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED), again)
        assertFalse(again.relay)
    }

    @Test
    fun `V1 then V3 - a mesh service attached later is not handed V1`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V3))
        val restarted = RecordingSyncSet()

        inbox.attachSyncSet(restarted)

        assertEquals(listOf(V3_MESSAGE_ID), restarted.messageIds())
    }

    @Test
    fun `V3 heard again, or first read from the backend and then heard, withdraws V1 once`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))
        inbox.onBackendNotice(V3)
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V3, ttl = 6u))
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V3, ttl = 5u))
        inbox.onBackendNotice(V3)

        assertEquals(listOf("present $V1_MESSAGE_ID", "withdraw $V1_MESSAGE_ID"), presenter.events)
        assertEquals(listOf(V1_MESSAGE_ID), sync.removed)
    }

    // ── 取代（帶內容）──────────────────────────────────────────────────────

    @Test
    fun `a correction marks V1 corrected by it, then is presented itself`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))

        val outcome = inbox.onMeshPacket(TestAdminNotices.meshPacket(CORRECTION))

        assertTrue(outcome.relay)
        assertEquals(
            listOf("present $V1_MESSAGE_ID", "correct $V1_MESSAGE_ID by $CORRECTION_ID", "present $CORRECTION_ID"),
            presenter.events
        )
        assertEquals(listOf(V1_MESSAGE_ID), sync.removed)
        assertEquals(listOf(V1_MESSAGE_ID, CORRECTION_ID), sync.messageIds())
    }

    @Test
    fun `a correction read before V1 - V1 is dropped and the correction stays the one shown`() {
        inbox.onBackendNotice(CORRECTION)

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED), inbox.onBackendNotice(V1))
        assertFalse(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)
        assertEquals(listOf("correct $V1_MESSAGE_ID by $CORRECTION_ID", "present $CORRECTION_ID"), presenter.events)
    }

    // ── 定向公告（#141）───────────────────────────────────────────────────

    @Test
    fun `a pure revoke, always a broadcast, withdraws a targeted notice too`() {
        val recipient = recipientInbox()
        recipient.onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertTrue(recipient.onMeshPacket(TestAdminNotices.meshPacket(revokeOf(V2_MESSAGE_ID, expiresAt = V2_EXPIRES_AT))).relay)

        assertEquals(listOf("present $V2_MESSAGE_ID", "withdraw $V2_MESSAGE_ID"), presenter.events)
    }

    @Test
    fun `a targeted correction for this device marks the original corrected, then is presented`() {
        val recipient = recipientInbox()
        recipient.onMeshPacket(TestAdminNotices.meshPacket(V2))

        recipient.onMeshPacket(TestAdminNotices.meshPacket(targetedCorrectionOfV2(to = RECIPIENT_1_PRIVATE_HEX)))

        assertEquals(
            listOf("present $V2_MESSAGE_ID", "correct $V2_MESSAGE_ID by $CORRECTION_ID", "present $CORRECTION_ID"),
            presenter.events
        )
    }

    @Test
    fun `a targeted correction this device cannot open still marks the original corrected, and is relayed`() {
        val recipient = recipientInbox()
        recipient.onMeshPacket(TestAdminNotices.meshPacket(V2))

        val outcome = recipient.onMeshPacket(TestAdminNotices.meshPacket(targetedCorrectionOfV2(to = RECIPIENT_2_PRIVATE_HEX)))

        assertTrue(outcome.relay)
        assertEquals(listOf("present $V2_MESSAGE_ID", "correct $V2_MESSAGE_ID by $CORRECTION_ID"), presenter.events)
    }

    /** An Inbox holding recipient-1's key, which opens V2. */
    private fun recipientInbox() = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = presenter,
        nowMs = { now },
        injectionScheduler = ManualScheduler(),
        recipientKey = FakeRecipientKey(RECIPIENT_1_PRIVATE_HEX)
    )

    private fun targetedCorrectionOfV2(to: String) = TestAdminNotices.targeted(
        recipients = listOf(requireNotNull(FakeRecipientKey(to).publicKey())),
        content = "救援人員改約 30 分鐘後抵達",
        messageId = CORRECTION_ID,
        expiresAt = V2_EXPIRES_AT,
        replaces = V2_MESSAGE_ID
    )

    // ── 先驗簽才寫撤回紀錄 ───────────────────────────────────────────────────

    @Test
    fun `a forged revoke withdraws nothing, whichever arrives first`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(FORGED_V3))
        inbox.onBackendNotice(FORGED_V3)

        assertTrue("V1 is still accepted", inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)
        assertEquals(
            AdminNoticeOutcome.Rejected(AdminNoticeRejection.BAD_SIGNATURE),
            inbox.onMeshPacket(TestAdminNotices.meshPacket(FORGED_V3, ttl = 3u))
        )
        assertEquals(listOf("present $V1_MESSAGE_ID"), presenter.events)
        assertTrue(sync.removed.isEmpty())
    }

    @Test
    fun `a revoke that fails any check before step 7 revokes nothing`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V3, timestamp = V3_ISSUED_AT + 1)) // outer mismatch
        inbox.onBackendNotice(TestAdminNotices.signed(replaces = V1_MESSAGE_ID, keyId = 0x02, body = ByteArray(0)))
        inbox.onBackendNotice(
            TestAdminNotices.signed(
                replaces = V1_MESSAGE_ID,
                body = ByteArray(0),
                issuedAt = now + 11 * 60_000L,
                expiresAt = now + HOUR
            )
        )

        assertTrue(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)
        assertEquals(listOf("present $V1_MESSAGE_ID"), presenter.events)
    }

    // ── 撤回紀錄的保留期與上限 ───────────────────────────────────────────────

    @Test
    fun `the revocation record is kept until the replacing notice's expiresAt plus the clock tolerance`() {
        val original = TestAdminNotices.signed(messageId = ORIGINAL_ID, issuedAt = now, expiresAt = now + 3 * HOUR)
        inbox.onBackendNotice(revokeOf(ORIGINAL_ID, expiresAt = now + HOUR))
        val revokeKeptUntil = now + HOUR + 10 * 60_000L

        now = revokeKeptUntil
        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED), inbox.onBackendNotice(original))

        now = revokeKeptUntil + 1
        assertEquals(AdminNoticeOutcome.Accepted::class, inbox.onBackendNotice(original)::class)
    }

    @Test
    fun `when the revocation record is full the revocation expiring first is forgotten`() {
        val small = AdminNoticeInbox(TestAdminNotices.TEST_KEYS, presenter, { now }, ManualScheduler(), maxRecords = 2)
        small.onBackendNotice(revokeOf("0000000000000001", messageId = "00000000000000a1", expiresAt = now + HOUR))
        small.onBackendNotice(revokeOf("0000000000000002", messageId = "00000000000000a2", expiresAt = now + 2 * HOUR))
        small.onBackendNotice(revokeOf("0000000000000003", messageId = "00000000000000a3", expiresAt = now + 3 * HOUR))

        assertEquals(
            AdminNoticeOutcome.Accepted::class,
            small.onBackendNotice(TestAdminNotices.signed(messageId = "0000000000000001", issuedAt = now))::class
        )
        assertEquals(
            AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED),
            small.onBackendNotice(TestAdminNotices.signed(messageId = "0000000000000002", issuedAt = now))
        )
    }

    // ── 先收到 V3 再收到 V1 ──────────────────────────────────────────────────

    @Test
    fun `V3 then V1 over the mesh - V1 is dropped, neither relayed nor presented nor offered to sync`() {
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V3))

        val original = inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED), original)
        assertFalse(original.relay)
        assertEquals("nothing was ever shown for V1", listOf("withdraw $V1_MESSAGE_ID"), presenter.events)
        assertEquals(listOf(V3_MESSAGE_ID), sync.messageIds())
    }

    @Test
    fun `V3 then V1 from the backend - V1 is dropped and never injected`() {
        inbox.onBackendNotice(V3)

        val original = inbox.onBackendNotice(V1)
        advance(15_000)

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED), original)
        assertEquals(listOf("withdraw $V1_MESSAGE_ID"), presenter.events)
        assertEquals("only the revoke is injected", listOf(V3_MESSAGE_ID), mesh.injectedIds())
    }

    @Test
    fun `V3 from the backend, then V1 over the mesh - V1 is not relayed`() {
        inbox.onBackendNotice(V3)

        assertFalse(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)
        assertEquals(listOf("withdraw $V1_MESSAGE_ID"), presenter.events)
    }

    private fun advance(ms: Long) {
        now += ms
        scheduler.advance(ms)
    }

    private fun RecordingInjector.injectedIds() = injected.map { it.senderID.toHexString() }

    private class RecordingPresenter : AdminNoticePresenter {
        /** What the Inbox asked for, in order. */
        val events = mutableListOf<String>()

        override fun present(notice: ReceivedAdminNotice) {
            events += "present ${notice.messageId}"
        }

        override fun correct(messageId: String, correctedBy: String) {
            events += "correct $messageId by $correctedBy"
        }

        override fun withdraw(messageId: String) {
            events += "withdraw $messageId"
        }
    }

    /** A pure revoke of [replaced] (broadcast kind, empty body), issued now. */
    private fun revokeOf(replaced: String, messageId: String = "99999999999999aa", expiresAt: Long) =
        TestAdminNotices.signed(messageId = messageId, issuedAt = now, expiresAt = expiresAt, replaces = replaced, body = ByteArray(0))

    private companion object {
        const val HOUR = 3_600_000L

        /** V3's issuedAt: ten minutes after V1's. */
        const val V3_ISSUED_AT = VECTOR_ISSUED_AT + 10 * 60_000L

        const val ORIGINAL_ID = "0123456789abcdef"
        const val CORRECTION_ID = "c0c0c0c0c0c0c0c0"

        /** Corrects V1: issued with V3, expiring with V1, with new text. */
        val CORRECTION = TestAdminNotices.signed(
            messageId = CORRECTION_ID,
            level = 0x03,
            issuedAt = V3_ISSUED_AT,
            expiresAt = TestAdminNotices.V1_EXPIRES_AT,
            replaces = V1_MESSAGE_ID,
            body = "土石流警戒：請改至中山國中避難所".toByteArray(Charsets.UTF_8)
        )

        /** V3 with one bit of its signature flipped. */
        val FORGED_V3 = V3.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 0x01).toByte() }
    }
}
