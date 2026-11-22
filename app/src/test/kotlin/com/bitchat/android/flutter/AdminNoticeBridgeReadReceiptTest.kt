package com.bitchat.android.flutter

import android.content.Context
import com.bitchat.android.adminnotice.AdminNoticeKind
import com.bitchat.android.adminnotice.AdminNoticeLevel
import com.bitchat.android.adminnotice.AdminNoticeStatus
import com.bitchat.android.adminnotice.EncryptedAdminNoticeStore
import com.bitchat.android.adminnotice.StoredAdminNotice
import com.bitchat.android.adminnotice.recordFirstRead
import com.bitchat.android.identity.AdminNoticeRecipientKeyStore
import com.bitchat.android.testsupport.ManualPoster
import com.bitchat.android.testsupport.Read
import com.bitchat.android.testsupport.RecordingReceipts
import com.bitchat.android.testsupport.RecordingResult
import io.flutter.plugin.common.MethodCall
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.util.UUID

/**
 * The readAt receipt (#143): `adminNotice_markRead` through [AdminNoticeBridge] with the receipt
 * port wired as `FlutterChatActivity` wires it ([recordFirstRead]). The store is the real one over
 * plain SharedPreferences; only the receipt port is a fake.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class AdminNoticeBridgeReadReceiptTest {

    private val dispatcher = StandardTestDispatcher()
    private val context: Context = RuntimeEnvironment.getApplication()
    private var now = ISSUED_AT + 60_000L
    private val notices = EncryptedAdminNoticeStore(
        openPrefs = { context.getSharedPreferences("admin-notice-read-${UUID.randomUUID()}", Context.MODE_PRIVATE) },
        nowMs = { now }
    )
    private val receipts = RecordingReceipts()
    private val bridge = AdminNoticeBridge(
        keyStore = { AdminNoticeRecipientKeyStore(context.getSharedPreferences("unused-${UUID.randomUUID()}", Context.MODE_PRIVATE)) },
        notices = notices,
        events = BridgeEventEmitter(postToMain = ManualPoster(), logDropped = {}),
        onFirstRead = receipts::recordFirstRead,
        scope = CoroutineScope(dispatcher + Job()),
        storeDispatcher = dispatcher
    )

    private fun markRead(messageId: String): RecordingResult {
        val result = RecordingResult()
        assertTrue(bridge.handle(MethodCall(AdminNoticeBridge.METHOD_MARK_READ, mapOf("messageId" to messageId)), result))
        dispatcher.scheduler.advanceUntilIdle()
        return result
    }

    @Test
    fun `reading a targeted notice for the first time writes its readAt`() {
        notices.insertIfAbsent(RESCUE_ON_THE_WAY)
        now += 5 * 60_000L

        markRead(RESCUE_ON_THE_WAY.messageId)

        assertEquals(listOf(Read(RESCUE_ON_THE_WAY.messageId, now)), receipts.read)
    }

    @Test
    fun `reading a broadcast writes nothing`() {
        notices.insertIfAbsent(EVACUATION)

        markRead(EVACUATION.messageId)

        assertEquals(emptyList<Read>(), receipts.read)
    }

    @Test
    fun `reading a targeted notice again writes nothing more`() {
        notices.insertIfAbsent(RESCUE_ON_THE_WAY)

        markRead(RESCUE_ON_THE_WAY.messageId)
        now += 60_000L
        markRead(RESCUE_ON_THE_WAY.messageId)

        assertEquals(listOf(Read(RESCUE_ON_THE_WAY.messageId, ISSUED_AT + 60_000L)), receipts.read)
    }

    @Test
    fun `a read receipt that cannot be written still marks the notice read`() {
        receipts.failWith = IllegalStateException("Firestore is gone")
        notices.insertIfAbsent(RESCUE_ON_THE_WAY)

        val result = markRead(RESCUE_ON_THE_WAY.messageId)

        assertEquals(listOf("success:null"), result.calls)
        assertEquals(true, notices.all().single().isRead)
    }
}

private const val ISSUED_AT = 1_792_627_200_000L

private val RESCUE_ON_THE_WAY = StoredAdminNotice(
    messageId = "0f1e2d3c4b5a6978",
    kind = AdminNoticeKind.TARGETED,
    level = AdminNoticeLevel.IMPORTANT,
    issuedAtMs = ISSUED_AT,
    expiresAtMs = ISSUED_AT + 2 * 3_600_000L,
    replaces = null,
    content = "救援人員約 10 分鐘內抵達，請留在原地",
    status = AdminNoticeStatus.ACTIVE,
    receivedAtMs = ISSUED_AT + 30_000L
)

private val EVACUATION = StoredAdminNotice(
    messageId = "a1b2c3d4e5f60718",
    kind = AdminNoticeKind.BROADCAST,
    level = AdminNoticeLevel.URGENT,
    issuedAtMs = ISSUED_AT,
    expiresAtMs = ISSUED_AT + 6 * 3_600_000L,
    replaces = null,
    content = "土石流警戒：請立即撤離至大同國小避難所",
    status = AdminNoticeStatus.ACTIVE,
    receivedAtMs = ISSUED_AT + 30_000L
)
