package com.bitchat.android.adminnotice

import com.bitchat.android.adminnotice.TestAdminNotices.V1
import com.bitchat.android.adminnotice.TestAdminNotices.V1_CONTENT
import com.bitchat.android.adminnotice.TestAdminNotices.V1_EXPIRES_AT
import com.bitchat.android.adminnotice.TestAdminNotices.V1_MESSAGE_ID
import com.bitchat.android.adminnotice.TestAdminNotices.V2
import com.bitchat.android.adminnotice.TestAdminNotices.V2_MESSAGE_ID
import com.bitchat.android.adminnotice.TestAdminNotices.V3
import com.bitchat.android.adminnotice.TestAdminNotices.V3_MESSAGE_ID
import com.bitchat.android.adminnotice.TestAdminNotices.V4
import com.bitchat.android.adminnotice.TestAdminNotices.VECTOR_ISSUED_AT
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AdminNoticeInbox（#136，docs/ADMIN_NOTICE_V1.md「處理規則」）：只看對外行為——給定 Firestore 交來的
 * `wire` 與時間，觀察回傳的結果與呈現 port 收到什麼。公鑰表只有 test vector 的金鑰，時鐘是 fake。
 */
class AdminNoticeInboxTest {

    /** A minute after the vectors were issued. */
    private var now = VECTOR_ISSUED_AT + 60_000L
    private val presenter = RecordingPresenter()

    private fun inbox(keys: AdminKeyTable = TestAdminNotices.TEST_KEYS) =
        AdminNoticeInbox(adminKeys = keys, presenter = presenter, nowMs = { now }, injectionScheduler = ManualScheduler())

    // ── 附錄的 test vectors ─────────────────────────────────────────────────

    @Test
    fun `V1 from the backend is verified and presented`() {
        val outcome = inbox().onBackendNotice(V1)

        assertEquals(AdminNoticeOutcome.Accepted::class, outcome::class)
        val shown = presenter.shown.single()
        assertEquals(V1_MESSAGE_ID, shown.messageId)
        assertEquals(AdminNoticeLevel.URGENT, shown.level)
        assertEquals(V1_CONTENT, shown.content)
        assertEquals(VECTOR_ISSUED_AT, shown.issuedAtMs)
        assertEquals(V1_EXPIRES_AT, shown.expiresAtMs)
        assertEquals(AdminNoticeKind.BROADCAST, shown.kind)
    }

    @Test
    fun `V4, V1 with its level tampered, is rejected and not presented`() {
        val outcome = inbox().onBackendNotice(V4)

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.BAD_SIGNATURE), outcome)
        assertTrue(presenter.shown.isEmpty())
    }

    @Test
    fun `the production App does not trust a notice signed with the test-vector key`() {
        val outcome = inbox(keys = AdminKeyTable.PRODUCTION).onBackendNotice(V1)

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.BAD_SIGNATURE), outcome)
        assertTrue(presenter.shown.isEmpty())
    }

    // ── 各步檢查 ───────────────────────────────────────────────────────────

    @Test
    fun `a keyId this App does not know is rejected`() {
        val outcome = inbox().onBackendNotice(TestAdminNotices.signed(keyId = 0x02))

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.UNKNOWN_KEY_ID), outcome)
        assertTrue(presenter.shown.isEmpty())
    }

    @Test
    fun `a payload shorter than header and signature is rejected`() {
        assertRejected(AdminNoticeRejection.MALFORMED, V3.copyOf(99))
    }

    @Test
    fun `broadcast content over 300 bytes is rejected, 300 bytes is accepted`() {
        assertRejected(AdminNoticeRejection.MALFORMED, TestAdminNotices.signed(body = ByteArray(301) { 'a'.code.toByte() }))

        val outcome = inbox().onBackendNotice(TestAdminNotices.signed(body = ByteArray(300) { 'a'.code.toByte() }))

        assertEquals(AdminNoticeOutcome.Accepted::class, outcome::class)
    }

    @Test
    fun `an empty broadcast that withdraws nothing is rejected`() {
        assertRejected(AdminNoticeRejection.MALFORMED, TestAdminNotices.signed(body = ByteArray(0)))
    }

    @Test
    fun `a targeted body that does not match its recipient count is rejected`() {
        val oneEntryShort = TestAdminNotices.targetedBody(recipientCount = 3, contentBytes = 20).copyOf(33 + 40 * 2)

        assertRejected(AdminNoticeRejection.MALFORMED, TestAdminNotices.signed(kind = 0x02, body = oneEntryShort))
        assertRejected(AdminNoticeRejection.MALFORMED, TestAdminNotices.signed(kind = 0x02, body = TestAdminNotices.targetedBody(0, 20)))
        assertRejected(AdminNoticeRejection.MALFORMED, TestAdminNotices.signed(kind = 0x02, body = TestAdminNotices.targetedBody(6, 20)))
        assertRejected(AdminNoticeRejection.MALFORMED, TestAdminNotices.signed(kind = 0x02, body = TestAdminNotices.targetedBody(1, 301)))
    }

    @Test
    fun `an unknown version, kind or level is rejected`() {
        assertRejected(AdminNoticeRejection.UNSUPPORTED, TestAdminNotices.signed(version = 0x02))
        assertRejected(AdminNoticeRejection.UNSUPPORTED, TestAdminNotices.signed(kind = 0x03))
        assertRejected(AdminNoticeRejection.UNSUPPORTED, TestAdminNotices.signed(level = 0x00))
        assertRejected(AdminNoticeRejection.UNSUPPORTED, TestAdminNotices.signed(level = 0x04))
    }

    @Test
    fun `an all-zero messageId is rejected`() {
        assertRejected(AdminNoticeRejection.MALFORMED, TestAdminNotices.signed(messageId = "0000000000000000"))
    }

    @Test
    fun `a notice issued more than ten minutes ahead of this device's clock is rejected`() {
        now = VECTOR_ISSUED_AT - TEN_MINUTES - 1

        assertRejected(AdminNoticeRejection.ISSUED_IN_FUTURE, V1)
    }

    @Test
    fun `a notice issued exactly ten minutes ahead is within the clock tolerance`() {
        now = VECTOR_ISSUED_AT - TEN_MINUTES

        assertEquals(AdminNoticeOutcome.Accepted::class, inbox().onBackendNotice(V1)::class)
    }

    @Test
    fun `a notice more than ten minutes past its expiry is rejected`() {
        now = V1_EXPIRES_AT + TEN_MINUTES + 1

        assertRejected(AdminNoticeRejection.EXPIRED, V1)
    }

    @Test
    fun `a notice up to ten minutes past its expiry is within the clock tolerance`() {
        now = V1_EXPIRES_AT + TEN_MINUTES

        assertEquals(AdminNoticeOutcome.Accepted::class, inbox().onBackendNotice(V1)::class)
    }

    @Test
    fun `a validity over 24 hours is rejected, exactly 24 hours is accepted`() {
        assertRejected(
            AdminNoticeRejection.BAD_VALIDITY,
            TestAdminNotices.signed(expiresAt = VECTOR_ISSUED_AT + TWENTY_FOUR_HOURS + 1)
        )

        val outcome = inbox().onBackendNotice(TestAdminNotices.signed(expiresAt = VECTOR_ISSUED_AT + TWENTY_FOUR_HOURS))

        assertEquals(AdminNoticeOutcome.Accepted::class, outcome::class)
    }

    @Test
    fun `a notice that expires before or when it is issued is rejected`() {
        assertRejected(AdminNoticeRejection.BAD_VALIDITY, TestAdminNotices.signed(expiresAt = VECTOR_ISSUED_AT))
        assertRejected(AdminNoticeRejection.BAD_VALIDITY, TestAdminNotices.signed(expiresAt = VECTOR_ISSUED_AT - 1))
    }

    @Test
    fun `a notice that replaces itself is rejected`() {
        val messageId = "1122334455667788"

        assertRejected(
            AdminNoticeRejection.REPLACES_ITSELF,
            TestAdminNotices.signed(messageId = messageId, replaces = messageId)
        )
    }

    // ── 去重 ───────────────────────────────────────────────────────────────

    @Test
    fun `the same notice received twice is presented once`() {
        val inbox = inbox()

        inbox.onBackendNotice(V1)
        inbox.onBackendNotice(TestAdminNotices.signed())
        val again = inbox.onBackendNotice(V1)

        assertEquals(AdminNoticeOutcome.Duplicate, again)
        assertEquals(listOf(V1_MESSAGE_ID, "1122334455667788"), presenter.shown.map { it.messageId })
    }

    @Test
    fun `a forged copy heard first does not take the genuine notice's messageId`() {
        val inbox = inbox()

        inbox.onBackendNotice(V4) // same messageId as V1, bad signature

        assertEquals(AdminNoticeOutcome.Accepted::class, inbox.onBackendNotice(V1)::class)
        assertEquals(listOf(V1_MESSAGE_ID), presenter.shown.map { it.messageId })
    }

    @Test
    fun `when the dedup table is full the notice expiring first is forgotten`() {
        val inbox = AdminNoticeInbox(TestAdminNotices.TEST_KEYS, presenter, { now }, ManualScheduler(), maxRecords = 2)
        val expiringFirst = TestAdminNotices.signed(messageId = "0000000000000001", expiresAt = VECTOR_ISSUED_AT + 3_600_000L)
        val expiringLater = TestAdminNotices.signed(messageId = "0000000000000002", expiresAt = VECTOR_ISSUED_AT + 7_200_000L)
        inbox.onBackendNotice(expiringFirst)
        inbox.onBackendNotice(expiringLater)

        inbox.onBackendNotice(TestAdminNotices.signed(messageId = "0000000000000003", expiresAt = VECTOR_ISSUED_AT + 10_800_000L))

        assertEquals(AdminNoticeOutcome.Duplicate, inbox.onBackendNotice(expiringLater))
        assertEquals(AdminNoticeOutcome.Accepted::class, inbox.onBackendNotice(expiringFirst)::class)
    }

    // ── 這張票還不呈現的公告 ─────────────────────────────────────────────────

    @Test
    fun `V2, a targeted notice, is verified and recorded but not presented before decryption exists`() {
        val inbox = inbox()

        val outcome = inbox.onBackendNotice(V2)

        val payload = (outcome as AdminNoticeOutcome.Accepted).payload
        assertEquals(V2_MESSAGE_ID, payload.messageId)
        assertEquals(AdminNoticeKind.TARGETED, payload.kind)
        assertEquals(AdminNoticeLevel.IMPORTANT, payload.level)
        val body = payload.body as AdminNoticeBody.Targeted
        assertEquals(2, body.recipients.size)
        assertArrayEquals(hex("b043ecb010281c9b"), body.recipients[0].tag)
        assertArrayEquals(hex("43fb345512ecf908e41ec2e45803d25bea94f03a26de91c2192764c31b4e8b6e"), body.recipients[1].wrappedKey)
        assertArrayEquals(hex("b843ea2414803cdaa677b432"), body.nonce)
        assertEquals(52 + 16, body.ciphertext.size)
        assertTrue(presenter.shown.isEmpty())
        assertEquals(AdminNoticeOutcome.Duplicate, inbox.onBackendNotice(V2))
    }

    @Test
    fun `V3, a pure revoke, is verified and recorded but has nothing to present`() {
        val inbox = inbox()

        val outcome = inbox.onBackendNotice(V3)

        val payload = (outcome as AdminNoticeOutcome.Accepted).payload
        assertEquals(V3_MESSAGE_ID, payload.messageId)
        assertEquals(V1_MESSAGE_ID, payload.replaces)
        assertTrue(presenter.shown.isEmpty())
        assertEquals(AdminNoticeOutcome.Duplicate, inbox.onBackendNotice(V3))
    }

    @Test
    fun `a correction carries the messageId it replaces`() {
        inbox().onBackendNotice(TestAdminNotices.signed(replaces = V1_MESSAGE_ID))

        assertEquals(V1_MESSAGE_ID, presenter.shown.single().replaces)
    }

    // ── mesh 來源（#137）─────────────────────────────────────────────────────

    @Test
    fun `V1 heard over the mesh is verified, presented and relayed`() {
        val outcome = inbox().onMeshPacket(TestAdminNotices.meshPacket(V1))

        assertTrue(outcome.relay)
        val shown = presenter.shown.single()
        assertEquals(V1_MESSAGE_ID, shown.messageId)
        assertEquals(V1_CONTENT, shown.content)
    }

    @Test
    fun `V4 heard over the mesh is not relayed`() {
        val outcome = inbox().onMeshPacket(TestAdminNotices.meshPacket(V4))

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.BAD_SIGNATURE), outcome)
        assertFalse(outcome.relay)
        assertTrue(presenter.shown.isEmpty())
    }

    @Test
    fun `a packet whose senderID is not the notice's messageId is not relayed`() {
        val outcome = inbox().onMeshPacket(TestAdminNotices.meshPacket(V1, senderID = hex("aaaabbbbccccdddd")))

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.OUTER_MISMATCH), outcome)
        assertFalse(outcome.relay)
        assertTrue(presenter.shown.isEmpty())
    }

    @Test
    fun `a packet whose timestamp is not the notice's issuedAt is not relayed`() {
        val outcome = inbox().onMeshPacket(TestAdminNotices.meshPacket(V1, timestamp = VECTOR_ISSUED_AT + 1))

        assertEquals(AdminNoticeOutcome.Rejected(AdminNoticeRejection.OUTER_MISMATCH), outcome)
        assertTrue(presenter.shown.isEmpty())
    }

    @Test
    fun `V2, a targeted notice heard over the mesh, is verified and relayed but not presented`() {
        val outcome = inbox().onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertEquals(V2_MESSAGE_ID, (outcome as AdminNoticeOutcome.Accepted).payload.messageId)
        assertTrue(outcome.relay)
        assertTrue(presenter.shown.isEmpty())
    }

    @Test
    fun `a forged copy heard over the mesh first does not block the genuine one`() {
        val inbox = inbox()

        assertFalse(inbox.onMeshPacket(TestAdminNotices.meshPacket(V4)).relay) // V1's messageId, bad signature

        assertTrue(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)
        assertEquals(listOf(V1_MESSAGE_ID), presenter.shown.map { it.messageId })
    }

    @Test
    fun `a mismatched outer packet does not take the genuine notice's messageId`() {
        val inbox = inbox()
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, timestamp = VECTOR_ISSUED_AT + 1))

        assertTrue(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)
        assertEquals(listOf(V1_MESSAGE_ID), presenter.shown.map { it.messageId })
    }

    // ── 去重的三種情況（mesh 來源）──────────────────────────────────────────

    @Test
    fun `a notice already in the mesh is a duplicate and not relayed again`() {
        val inbox = inbox()
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 6u))

        val again = inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 3u))

        assertEquals(AdminNoticeOutcome.Duplicate, again)
        assertFalse(again.relay)
        assertEquals(1, presenter.shown.size)
    }

    @Test
    fun `a notice only read from the backend is relayed when heard over the mesh, but not presented again`() {
        val inbox = inbox()
        inbox.onBackendNotice(V1)

        val heard = inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))

        assertTrue(heard.relay)
        assertEquals(1, presenter.shown.size)
        assertFalse(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 2u)).relay)
    }

    @Test
    fun `a notice never seen before is recorded and relayed`() {
        val inbox = inbox()

        assertTrue(inbox.onMeshPacket(TestAdminNotices.meshPacket(V1)).relay)
        assertEquals(AdminNoticeOutcome.Duplicate, inbox.onBackendNotice(V1))
    }

    /** Rejected for [reason] — not for an earlier step — and nothing presented. */
    private fun assertRejected(reason: AdminNoticeRejection, wire: ByteArray) {
        assertEquals(AdminNoticeOutcome.Rejected(reason), inbox().onBackendNotice(wire))
        assertTrue(presenter.shown.isEmpty())
    }

    private class RecordingPresenter : AdminNoticePresenter {
        val shown = mutableListOf<ReceivedAdminNotice>()
        override fun present(notice: ReceivedAdminNotice) {
            shown += notice
        }
    }

    private companion object {
        const val TEN_MINUTES = 10 * 60_000L
        const val TWENTY_FOUR_HOURS = 24 * 3_600_000L
    }
}
