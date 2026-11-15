package com.bitchat.android.adminnotice

import android.content.Context
import android.os.Build
import com.bitchat.android.adminnotice.TestAdminNotices.RECIPIENT_1_PRIVATE_HEX
import com.bitchat.android.adminnotice.TestAdminNotices.V2
import com.bitchat.android.adminnotice.TestAdminNotices.V2_CONTENT
import com.bitchat.android.adminnotice.TestAdminNotices.VECTOR_ISSUED_AT
import com.bitchat.android.identity.AdminNoticeRecipientKeyStore
import com.bitchat.android.testsupport.FakeAndroidKeyStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.UUID

/**
 * The Inbox opening targeted notices with the App's real recipient key store (#140, #141): the key
 * registered at sign-in opens them, and once a sign-out (`adminNotice_clearKey`) clears it, nothing
 * more is presented, while every notice is still relayed.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class StoredAdminNoticeRecipientKeyTest {

    private val context: Context = RuntimeEnvironment.getApplication()
    private val shown = mutableListOf<ReceivedAdminNotice>()

    private fun inbox(recipientKey: AdminNoticeRecipientKey) = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) {
                shown += notice
            }
        },
        nowMs = { VECTOR_ISSUED_AT + 60_000L },
        injectionScheduler = ManualScheduler(),
        recipientKey = recipientKey
    )

    /** A store whose sign-in generates recipient-1's key, so V2 is for this device. */
    private fun recipient1Store() = AdminNoticeRecipientKeyStore(
        context.getSharedPreferences("admin-notice-key-${UUID.randomUUID()}", Context.MODE_PRIVATE),
        newPrivateKey = { hex(RECIPIENT_1_PRIVATE_HEX) }
    )

    @Test
    fun `signed in with recipient-1's key, V2 is opened and presented`() {
        val store = recipient1Store().also { it.publicKeyFor("uid-recipient-1") }

        inbox(StoredAdminNoticeRecipientKey { store }).onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertEquals(V2_CONTENT, shown.single().content)
    }

    @Test
    fun `after a sign-out clears the key, V2 is relayed but not presented`() {
        val store = recipient1Store().also { it.publicKeyFor("uid-recipient-1") }
        val inbox = inbox(StoredAdminNoticeRecipientKey { store })

        store.clear()
        val outcome = inbox.onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertTrue(outcome.relay)
        assertTrue(shown.isEmpty())
    }

    @Test
    fun `the store the Flutter bridge registers and clears is the one the Inbox opens notices with`() {
        FakeAndroidKeyStore.install()
        try {
            val inbox = inbox(StoredAdminNoticeRecipientKey { AdminNoticeRecipientKeyStore.getInstance(context) })
            // adminNotice_getPublicKey at sign-in: Flutter registers this as noticePublicKey.
            val registered = AdminNoticeRecipientKeyStore.getInstance(context).publicKeyFor("uid-alice")
            inbox.onBackendNotice(TestAdminNotices.targeted(listOf(registered), "請到二樓集合", messageId = "00000000000000a1"))

            // adminNotice_clearKey at sign-out.
            AdminNoticeRecipientKeyStore.getInstance(context).clear()
            inbox.onBackendNotice(TestAdminNotices.targeted(listOf(registered), "登出後才到", messageId = "00000000000000a2"))

            assertEquals(listOf("請到二樓集合"), shown.map { it.content })
        } finally {
            FakeAndroidKeyStore.uninstall()
        }
    }

    @Test
    fun `a key store that cannot be opened presents nothing, and the notice is still relayed`() {
        val unavailable = StoredAdminNoticeRecipientKey { throw IllegalStateException("keystore unavailable") }

        val outcome = inbox(unavailable).onMeshPacket(TestAdminNotices.meshPacket(V2))

        assertTrue(outcome.relay)
        assertTrue(shown.isEmpty())
    }
}
