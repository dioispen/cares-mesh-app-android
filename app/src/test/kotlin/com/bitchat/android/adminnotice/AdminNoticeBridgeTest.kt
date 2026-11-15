package com.bitchat.android.adminnotice

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hook the Gateway's Firestore listener hands `wire` through (#136): the listener never holds
 * the Inbox, and whatever the Inbox does, the listener's thread survives it.
 */
class AdminNoticeBridgeTest {

    private val shown = mutableListOf<ReceivedAdminNotice>()
    private val inbox = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) {
                shown += notice
            }
        },
        nowMs = { TestAdminNotices.VECTOR_ISSUED_AT }
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
    fun `uninstalling another Inbox leaves the installed one in place`() {
        AdminNoticeBridge.install(inbox)

        val replaced = AdminNoticeInbox(
            adminKeys = TestAdminNotices.TEST_KEYS,
            presenter = object : AdminNoticePresenter {
                override fun present(notice: ReceivedAdminNotice) = Unit
            },
            nowMs = { 0L }
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
            nowMs = { TestAdminNotices.VECTOR_ISSUED_AT }
        )
        AdminNoticeBridge.install(failing)
        try {
            assertNull(AdminNoticeBridge.deliverFromBackend(TestAdminNotices.V1))
            assertTrue(shown.isEmpty())
        } finally {
            AdminNoticeBridge.uninstall(failing)
        }
    }
}
