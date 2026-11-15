package com.bitchat.android.adminnotice

import android.content.Context
import android.os.Build
import com.bitchat.android.adminnotice.TestAdminNotices.V1
import com.bitchat.android.adminnotice.TestAdminNotices.V1_CONTENT
import com.bitchat.android.adminnotice.TestAdminNotices.V1_EXPIRES_AT
import com.bitchat.android.adminnotice.TestAdminNotices.V1_MESSAGE_ID
import com.bitchat.android.adminnotice.TestAdminNotices.VECTOR_ISSUED_AT
import com.bitchat.android.testsupport.FakeAndroidKeyStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * 本機儲存與通知（#136）: a received notice is stored by messageId and notified only on its first
 * insert, also across an App restart, when the in-memory dedup table starts empty again. The store
 * is the real encrypted one; only the notifier is a fake.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class LocalAdminNoticePresenterTest {

    private val context: Context = RuntimeEnvironment.getApplication()
    private var now = VECTOR_ISSUED_AT + 60_000L
    private val notified = mutableListOf<ReceivedAdminNotice>()
    private val notifier = object : AdminNoticeNotifier {
        override fun notify(notice: ReceivedAdminNotice) {
            notified += notice
        }
    }

    @Before
    fun setUp() {
        FakeAndroidKeyStore.install()
        context.getSharedPreferences(EncryptedAdminNoticeStore.PREFS_NAME, Context.MODE_PRIVATE).edit().clear().commit()
    }

    @After
    fun tearDown() {
        FakeAndroidKeyStore.uninstall()
    }

    /** What a process start builds: a fresh Inbox (empty dedup table) over the stored notices. */
    private fun startApp(): Pair<AdminNoticeInbox, EncryptedAdminNoticeStore> {
        val store = EncryptedAdminNoticeStore.open(context, nowMs = { now })
        val presenter = LocalAdminNoticePresenter(store, notifier, nowMs = { now })
        return AdminNoticeInbox(TestAdminNotices.TEST_KEYS, presenter, nowMs = { now }, injectionScheduler = ManualScheduler()) to store
    }

    @Test
    fun `a new notice is stored and notified`() {
        val (inbox, store) = startApp()

        inbox.onBackendNotice(V1)

        assertEquals(listOf(V1_MESSAGE_ID), notified.map { it.messageId })
        val stored = store.all().single()
        assertEquals(V1_MESSAGE_ID, stored.messageId)
        assertEquals(AdminNoticeKind.BROADCAST, stored.kind)
        assertEquals(AdminNoticeLevel.URGENT, stored.level)
        assertEquals(V1_CONTENT, stored.content)
        assertEquals(VECTOR_ISSUED_AT, stored.issuedAtMs)
        assertEquals(V1_EXPIRES_AT, stored.expiresAtMs)
        assertEquals(null, stored.replaces)
        assertEquals(AdminNoticeStatus.ACTIVE, stored.status)
        assertEquals(now, stored.receivedAtMs)
    }

    @Test
    fun `the same notice received twice is notified once`() {
        val (inbox, _) = startApp()

        inbox.onBackendNotice(V1)
        inbox.onBackendNotice(V1)

        assertEquals(1, notified.size)
    }

    @Test
    fun `a notice received again after an App restart is not notified again`() {
        startApp().first.onBackendNotice(V1)
        now += 3_600_000L

        val (restarted, store) = startApp()
        restarted.onBackendNotice(V1)

        assertEquals(1, notified.size)
        assertEquals("the first receipt is kept", VECTOR_ISSUED_AT + 60_000L, store.all().single().receivedAtMs)
    }

    @Test
    fun `a targeted notice is stored with its decrypted content, and that content is encrypted at rest`() {
        val store = EncryptedAdminNoticeStore.open(context, nowMs = { now })
        val inbox = AdminNoticeInbox(
            TestAdminNotices.TEST_KEYS,
            LocalAdminNoticePresenter(store, notifier, nowMs = { now }),
            nowMs = { now },
            injectionScheduler = ManualScheduler(),
            recipientKey = FakeRecipientKey(TestAdminNotices.RECIPIENT_1_PRIVATE_HEX)
        )

        inbox.onMeshPacket(TestAdminNotices.meshPacket(TestAdminNotices.V2))

        val stored = store.all().single()
        assertEquals(AdminNoticeKind.TARGETED, stored.kind)
        assertEquals(TestAdminNotices.V2_CONTENT, stored.content)
        val raw = context.getSharedPreferences(EncryptedAdminNoticeStore.PREFS_NAME, Context.MODE_PRIVATE).all
        val onDisk = raw.keys.joinToString() + raw.values.joinToString()
        assertFalse(onDisk.contains(TestAdminNotices.V2_MESSAGE_ID))
        assertFalse(onDisk.contains("救援人員"))
        assertFalse(onDisk.contains("TARGETED"))
    }

    @Test
    fun `notices are encrypted at rest`() {
        startApp().first.onBackendNotice(V1)

        val raw = context.getSharedPreferences(EncryptedAdminNoticeStore.PREFS_NAME, Context.MODE_PRIVATE).all
        val onDisk = raw.keys.joinToString() + raw.values.joinToString()

        assertFalse(raw.isEmpty())
        assertFalse(onDisk.contains(V1_MESSAGE_ID))
        assertFalse(onDisk.contains("土石流"))
    }
}
