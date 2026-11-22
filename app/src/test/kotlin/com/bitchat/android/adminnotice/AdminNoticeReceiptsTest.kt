package com.bitchat.android.adminnotice

import android.content.Context
import com.bitchat.android.testsupport.Delivered
import com.bitchat.android.testsupport.FakeRecipientKey
import com.bitchat.android.testsupport.ManualScheduler
import com.bitchat.android.testsupport.RecordingReceipts
import com.bitchat.android.testsupport.TestAdminNotices
import com.bitchat.android.testsupport.TestAdminNotices.RECIPIENT_1_PRIVATE_HEX
import com.bitchat.android.testsupport.TestAdminNotices.V2
import com.bitchat.android.testsupport.TestAdminNotices.V2_MESSAGE_ID
import com.bitchat.android.testsupport.TestAdminNotices.VECTOR_ISSUED_AT
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.util.UUID

/**
 * 回條（#143, docs/ADMIN_NOTICE_V1.md「回條」）as the Inbox and the presenter hand them to the
 * receipt port: a delivery receipt for each targeted notice this device opens, carrying where its
 * first copy came from. The Inbox, presenter and store are the real ones (the store over plain
 * SharedPreferences); only the receipt port and the notifier are fakes.
 */
@RunWith(RobolectricTestRunner::class)
class AdminNoticeReceiptsTest {

    private val context: Context = RuntimeEnvironment.getApplication()
    private val prefsName = "admin-notice-receipts-${UUID.randomUUID()}"
    private var now = VECTOR_ISSUED_AT + 60_000L
    private val receipts = RecordingReceipts()
    private val notified = mutableListOf<ReceivedAdminNotice>()

    /** What a process start builds: a fresh Inbox over the notices this device has stored. */
    private fun startApp(recipientKey: AdminNoticeRecipientKey = FakeRecipientKey(RECIPIENT_1_PRIVATE_HEX)): AdminNoticeInbox {
        val store = EncryptedAdminNoticeStore(
            openPrefs = { context.getSharedPreferences(prefsName, Context.MODE_PRIVATE) },
            nowMs = { now }
        )
        val notifier = object : AdminNoticeNotifier {
            override fun notify(notice: ReceivedAdminNotice) {
                notified += notice
            }

            // Receipts don't depend on whether a notification is taken back (#139).
            override fun cancel(messageId: String) = Unit
        }
        return AdminNoticeInbox(
            adminKeys = TestAdminNotices.TEST_KEYS,
            presenter = LocalAdminNoticePresenter(store, notifier, nowMs = { now }, receipts = receipts),
            nowMs = { now },
            injectionScheduler = ManualScheduler(),
            recipientKey = recipientKey
        )
    }

    @Test
    fun `a targeted notice read from Firestore and opened here is delivered via firestore`() {
        startApp().onBackendNotice(V2)

        assertEquals(listOf(Delivered(V2_MESSAGE_ID, AdminNoticeSource.BACKEND, now)), receipts.delivered)
    }

    @Test
    fun `a targeted notice heard over the mesh and opened here is delivered via ble`() {
        startApp().onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertEquals(listOf(Delivered(V2_MESSAGE_ID, AdminNoticeSource.MESH, now)), receipts.delivered)
    }

    @Test
    fun `a broadcast writes no receipt, from either path`() {
        val inbox = startApp()

        inbox.onBackendNotice(TestAdminNotices.V1)
        inbox.onMeshPacket(TestAdminNotices.meshPacket(TestAdminNotices.signed(messageId = "1122334455667788")))

        assertEquals(2, notified.size)
        assertEquals(emptyList<Delivered>(), receipts.delivered)
    }

    @Test
    fun `a device that is not a recipient writes no receipt, from either path`() {
        val outsider = startApp(recipientKey = FakeRecipientKey(TestAdminNotices.OUTSIDER_PRIVATE_HEX))
        outsider.onBackendNotice(V2)
        outsider.onMeshPacket(TestAdminNotices.meshPacket(TestAdminNotices.V5))
        startApp(recipientKey = AdminNoticeRecipientKey.NONE).onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertEquals(emptyList<Delivered>(), receipts.delivered)
    }

    @Test
    fun `only the first copy writes the receipt, so a Gateway that read it from Firestore and then heard it says firestore`() {
        val inbox = startApp()

        inbox.onBackendNotice(V2)
        now += 5_000L
        inbox.onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertEquals(listOf(Delivered(V2_MESSAGE_ID, AdminNoticeSource.BACKEND, VECTOR_ISSUED_AT + 60_000L)), receipts.delivered)
    }

    // After a restart the Gateway's listener reads every unexpired notice again, from Firestore:
    // a second receipt would move deliveredAt and could turn a `ble` delivery into `firestore`.
    @Test
    fun `a notice received again after an App restart keeps its first receipt`() {
        startApp().onMeshPacket(TestAdminNotices.meshPacket(V2))
        now += 3_600_000L

        startApp().onBackendNotice(V2)

        assertEquals(listOf(Delivered(V2_MESSAGE_ID, AdminNoticeSource.MESH, VECTOR_ISSUED_AT + 60_000L)), receipts.delivered)
    }

    @Test
    fun `a receipt that cannot be written does not hold up the notice`() {
        receipts.failWith = IllegalStateException("Firestore is gone")
        val inbox = startApp()

        val outcome = inbox.onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertEquals("still relayed", true, outcome.relay)
        assertEquals("still notified", listOf(V2_MESSAGE_ID), notified.map { it.messageId })
        assertEquals("still a duplicate the second time", AdminNoticeOutcome.Duplicate, inbox.onMeshPacket(TestAdminNotices.meshPacket(V2)))
    }
}
