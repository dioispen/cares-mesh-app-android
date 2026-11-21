package com.bitchat.android.adminnotice

import android.content.Context
import android.os.Build
import com.bitchat.android.adminnotice.TestAdminNotices.V1
import com.bitchat.android.adminnotice.TestAdminNotices.V1_CONTENT
import com.bitchat.android.adminnotice.TestAdminNotices.V1_EXPIRES_AT
import com.bitchat.android.adminnotice.TestAdminNotices.V1_MESSAGE_ID
import com.bitchat.android.adminnotice.TestAdminNotices.V3
import com.bitchat.android.adminnotice.TestAdminNotices.VECTOR_ISSUED_AT
import com.bitchat.android.testsupport.FakeAndroidKeyStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    /** Every post and cancellation, in order: "notify <messageId>" or "cancel <messageId>". */
    private val notifications = mutableListOf<String>()
    private val notifier = object : AdminNoticeNotifier {
        override fun notify(notice: ReceivedAdminNotice) {
            notified += notice
            notifications += "notify ${notice.messageId}"
        }

        override fun cancel(messageId: String) {
            notifications += "cancel $messageId"
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

    // ── 撤回與取代（#139）───────────────────────────────────────────────────

    @Test
    fun `V1 then V3 - V1 is stored as withdrawn without its content, and its notification cancelled`() {
        val (inbox, store) = startApp()
        var changes = 0
        store.addChangeListener { changes++ }

        inbox.onBackendNotice(V1)
        now += 60_000L
        inbox.onBackendNotice(V3)

        val stored = store.all().single()
        assertEquals(V1_MESSAGE_ID, stored.messageId)
        assertEquals(AdminNoticeStatus.WITHDRAWN, stored.status)
        assertEquals("", stored.content)
        assertEquals(listOf("notify $V1_MESSAGE_ID", "cancel $V1_MESSAGE_ID"), notifications)
        assertEquals("stored, then withdrawn", 2, changes)
    }

    @Test
    fun `a correction marks V1 corrected by it, cancels V1's notification and notifies itself`() {
        val (inbox, store) = startApp()

        inbox.onBackendNotice(V1)
        inbox.onBackendNotice(CORRECTION)

        val stored = store.all().associateBy { it.messageId }
        assertEquals(AdminNoticeStatus.CORRECTED, stored.getValue(V1_MESSAGE_ID).status)
        assertEquals(CORRECTION_ID, stored.getValue(V1_MESSAGE_ID).replacedBy)
        assertEquals("", stored.getValue(V1_MESSAGE_ID).content)
        assertEquals(AdminNoticeStatus.ACTIVE, stored.getValue(CORRECTION_ID).status)
        assertEquals(CORRECTION_CONTENT, stored.getValue(CORRECTION_ID).content)
        assertEquals(
            listOf("notify $V1_MESSAGE_ID", "cancel $V1_MESSAGE_ID", "notify $CORRECTION_ID"),
            notifications
        )
    }

    @Test
    fun `V3 then V1 - nothing is stored or notified for V1`() {
        val (inbox, store) = startApp()

        inbox.onBackendNotice(V3)
        inbox.onBackendNotice(V1)

        assertEquals(emptyList<StoredAdminNotice>(), store.all())
        assertTrue(notified.isEmpty())
    }

    @Test
    fun `after a restart, V1 and V3 delivered again in either order leave V1 withdrawn and notify nothing`() {
        startApp().first.run {
            onBackendNotice(V1)
            onBackendNotice(V3)
        }
        listOf(listOf(V1, V3), listOf(V3, V1)).forEach { order ->
            now += 60_000L
            val (restarted, store) = startApp()
            order.forEach { restarted.onBackendNotice(it) }

            val stored = store.all().single()
            assertEquals(AdminNoticeStatus.WITHDRAWN, stored.status)
            assertEquals("", stored.content)
        }

        assertEquals(listOf(V1_MESSAGE_ID), notified.map { it.messageId })
    }

    @Test
    fun `after a restart, V1 delivered again stays corrected and is not notified`() {
        startApp().first.run {
            onBackendNotice(V1)
            onBackendNotice(CORRECTION)
        }
        now += 60_000L

        val (restarted, store) = startApp()
        restarted.onMeshPacket(TestAdminNotices.meshPacket(V1))
        restarted.onMeshPacket(TestAdminNotices.meshPacket(CORRECTION))

        val stored = store.all().associateBy { it.messageId }
        assertEquals(AdminNoticeStatus.CORRECTED, stored.getValue(V1_MESSAGE_ID).status)
        assertEquals(CORRECTION_ID, stored.getValue(V1_MESSAGE_ID).replacedBy)
        assertEquals(listOf(V1_MESSAGE_ID, CORRECTION_ID), notified.map { it.messageId })
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

    private companion object {
        const val CORRECTION_ID = "c0c0c0c0c0c0c0c0"
        const val CORRECTION_CONTENT = "土石流警戒：請改至中山國中避難所"

        /** Corrects V1: issued ten minutes after it, expiring with it. */
        val CORRECTION = TestAdminNotices.signed(
            messageId = CORRECTION_ID,
            level = 0x03,
            issuedAt = VECTOR_ISSUED_AT + 10 * 60_000L,
            expiresAt = V1_EXPIRES_AT,
            replaces = V1_MESSAGE_ID,
            body = CORRECTION_CONTENT.toByteArray(Charsets.UTF_8)
        )
    }
}
