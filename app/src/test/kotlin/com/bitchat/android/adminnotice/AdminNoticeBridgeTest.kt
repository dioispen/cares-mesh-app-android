package com.bitchat.android.adminnotice

import com.bitchat.android.testsupport.ManualScheduler
import com.bitchat.android.testsupport.RecordingInjector
import com.bitchat.android.testsupport.RecordingSyncSet
import com.bitchat.android.testsupport.TestAdminNotices
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hook the Gateway's Firestore listener (#136) and the mesh (#137) hand notices through: neither
 * holds the Inbox, and whatever the Inbox does, their threads survive it.
 */
class AdminNoticeBridgeTest {

    private val shown = mutableListOf<ReceivedAdminNotice>()
    private val scheduler = ManualScheduler()
    private val inbox = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) {
                shown += notice
            }
        },
        nowMs = { TestAdminNotices.VECTOR_ISSUED_AT },
        injectionScheduler = scheduler,
        injectionDelayMs = { 5_000L }
    )

    @After
    fun tearDown() {
        AdminNoticeBridge.uninstall(inbox)
    }

    @Test
    fun `a notice from the backend reaches the installed Inbox`() {
        AdminNoticeBridge.install(inbox)

        val outcome = AdminNoticeBridge.deliverFromBackend(TestAdminNotices.V1)

        assertEquals(AdminNoticeOutcome.Accepted::class, outcome!!::class)
        assertEquals(TestAdminNotices.V1_MESSAGE_ID, shown.single().messageId)
    }

    @Test
    fun `without an Inbox a notice is dropped`() {
        assertNull(AdminNoticeBridge.deliverFromBackend(TestAdminNotices.V1))
    }

    @Test
    fun `a 0x31 packet from the mesh reaches the installed Inbox, which decides the relay`() {
        AdminNoticeBridge.install(inbox)

        assertTrue(AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.V1)))
        assertFalse(AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.V1, ttl = 3u)))
        assertFalse(AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.V4)))
        assertEquals(TestAdminNotices.V1_MESSAGE_ID, shown.single().messageId)
    }

    @Test
    fun `without an Inbox nothing can verify a 0x31 packet, so it is not relayed`() {
        assertFalse(AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.V1)))
    }

    @Test
    fun `the mesh service attached through the bridge injects, and detaching it cancels`() {
        AdminNoticeBridge.install(inbox)
        val mesh = RecordingInjector()
        val sync = RecordingSyncSet()
        AdminNoticeBridge.attachMesh(mesh, sync)
        AdminNoticeBridge.deliverFromBackend(TestAdminNotices.V1)
        scheduler.advance(5_000)
        AdminNoticeBridge.deliverFromBackend(TestAdminNotices.signed())

        AdminNoticeBridge.detachMesh(mesh, sync)
        scheduler.advance(5_000)

        assertEquals(listOf(TestAdminNotices.V1_MESSAGE_ID), mesh.injected.map { it.senderID.toHex() })
    }

    @Test
    fun `the mesh service attached through the bridge gets the notices in the mesh, until it detaches`() {
        AdminNoticeBridge.install(inbox)
        AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.V1))
        val mesh = RecordingInjector()
        val sync = RecordingSyncSet()

        AdminNoticeBridge.attachMesh(mesh, sync)
        AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.V2))
        AdminNoticeBridge.detachMesh(mesh, sync)
        AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.signed()))

        assertEquals(listOf(TestAdminNotices.V1_MESSAGE_ID, TestAdminNotices.V2_MESSAGE_ID), sync.messageIds())
    }

    @Test
    fun `uninstalling another Inbox leaves the installed one in place`() {
        AdminNoticeBridge.install(inbox)

        val replaced = AdminNoticeInbox(
            adminKeys = TestAdminNotices.TEST_KEYS,
            presenter = object : AdminNoticePresenter {
                override fun present(notice: ReceivedAdminNotice) = Unit
            },
            nowMs = { 0L },
            injectionScheduler = ManualScheduler()
        )
        AdminNoticeBridge.uninstall(replaced)

        assertEquals(AdminNoticeOutcome.Accepted::class, AdminNoticeBridge.deliverFromBackend(TestAdminNotices.V1)!!::class)
    }

    @Test
    fun `a failing presenter does not reach the listener`() {
        val failing = AdminNoticeInbox(
            adminKeys = TestAdminNotices.TEST_KEYS,
            presenter = object : AdminNoticePresenter {
                override fun present(notice: ReceivedAdminNotice) = throw IllegalStateException("store unavailable")
            },
            nowMs = { TestAdminNotices.VECTOR_ISSUED_AT },
            injectionScheduler = ManualScheduler()
        )
        AdminNoticeBridge.install(failing)
        try {
            assertNull(AdminNoticeBridge.deliverFromBackend(TestAdminNotices.V1))
            assertFalse(AdminNoticeBridge.deliverFromMesh(TestAdminNotices.meshPacket(TestAdminNotices.signed())))
            assertTrue(shown.isEmpty())
        } finally {
            AdminNoticeBridge.uninstall(failing)
        }
    }
}

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
