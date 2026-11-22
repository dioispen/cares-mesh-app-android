package com.bitchat.android.flutter

import android.content.Context
import android.content.SharedPreferences
import com.bitchat.android.adminnotice.AdminNoticeKind
import com.bitchat.android.adminnotice.AdminNoticeLevel
import com.bitchat.android.adminnotice.AdminNoticeStatus
import com.bitchat.android.adminnotice.EncryptedAdminNoticeStore
import com.bitchat.android.adminnotice.StoredAdminNotice
import com.bitchat.android.identity.AdminNoticeRecipientKeyStore
import com.bitchat.android.testsupport.ManualPoster
import com.bitchat.android.testsupport.RecordingAdminNoticeNotifier
import com.bitchat.android.testsupport.RecordingResult
import com.bitchat.android.testsupport.RecordingSink
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
import java.security.GeneralSecurityException
import java.util.UUID

/**
 * The notice list's half of [AdminNoticeBridge] (#142, docs/ADMIN_NOTICE_V1.md 收件端呈現):
 * `adminNotice_getAll`, `adminNotice_markRead` and the `admin_notice` event, over the real store
 * (plain SharedPreferences in place of the encrypted file) with the test's clock.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class AdminNoticeBridgeNoticeListTest {

    private val dispatcher = StandardTestDispatcher()
    private val context: Context = RuntimeEnvironment.getApplication()
    private val noticePrefs: SharedPreferences =
        context.getSharedPreferences("admin-notice-list-${UUID.randomUUID()}", Context.MODE_PRIVATE)
    private var now = ISSUED_AT + 60_000L
    private val notices = EncryptedAdminNoticeStore(openPrefs = { noticePrefs }, nowMs = { now })
    private val poster = ManualPoster()
    private val events = BridgeEventEmitter(postToMain = poster, logDropped = {})
    private val sink = RecordingSink()
    private val firstReads = mutableListOf<StoredAdminNotice>()
    private val bridge = AdminNoticeBridge(
        keyStore = { AdminNoticeRecipientKeyStore(context.getSharedPreferences("unused-${UUID.randomUUID()}", Context.MODE_PRIVATE)) },
        notices = notices,
        notifier = RecordingAdminNoticeNotifier(),
        events = events,
        onFirstRead = { firstReads += it },
        scope = CoroutineScope(dispatcher + Job()),
        storeDispatcher = dispatcher
    )

    private fun call(method: String, arguments: Any? = null, target: AdminNoticeBridge = bridge): RecordingResult {
        val result = RecordingResult()
        assertTrue("$method is claimed", target.handle(MethodCall(method, arguments), result))
        dispatcher.scheduler.advanceUntilIdle()
        return result
    }

    @Suppress("UNCHECKED_CAST")
    private fun getAll(): List<Map<String, Any?>> {
        val result = call(AdminNoticeBridge.METHOD_GET_ALL)
        assertEquals(1, result.calls.size)
        return result.values.single() as List<Map<String, Any?>>
    }

    private fun unreadCount() = getAll().count { it["read"] == false }

    /** Runs what the bridge queued: its store work, then delivery on the "main looper". */
    private fun deliverPending(): List<Any?> {
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        return sink.events.toList().also { sink.events.clear() }
    }

    @Test
    fun `getAll returns the stored notices, newest first`() {
        notices.insertIfAbsent(EVACUATION)
        notices.insertIfAbsent(SHELTER_OPEN)

        assertEquals(listOf(SHELTER_OPEN_MAP, EVACUATION_MAP), getAll())
    }

    @Test
    fun `getAll with nothing stored is an empty list`() {
        assertEquals(emptyList<Any?>(), getAll())
    }

    @Test
    fun `corrected and withdrawn notices come with their status, and a correction with its successor`() {
        notices.insertIfAbsent(EVACUATION.copy(status = AdminNoticeStatus.CORRECTED, replacedBy = SHELTER_OPEN.messageId))
        notices.insertIfAbsent(SHELTER_OPEN.copy(status = AdminNoticeStatus.WITHDRAWN))

        val byId = getAll().associateBy { it["messageId"] }

        assertEquals("corrected", byId.getValue(EVACUATION.messageId)["status"])
        assertEquals(SHELTER_OPEN.messageId, byId.getValue(EVACUATION.messageId)["replacedBy"])
        assertEquals("withdrawn", byId.getValue(SHELTER_OPEN.messageId)["status"])
    }

    @Test
    fun `a notice 7 days past expiresAt is no longer returned`() {
        notices.insertIfAbsent(EVACUATION)

        now = EVACUATION.expiresAtMs + 7 * DAY
        assertEquals("still there, as 已過期", 1, getAll().size)
        now += 1
        assertEquals(emptyList<Any?>(), getAll())
    }

    @Test
    fun `after markRead the unread count goes down`() {
        notices.insertIfAbsent(EVACUATION)
        notices.insertIfAbsent(SHELTER_OPEN)
        assertEquals(2, unreadCount())

        val marked = call(AdminNoticeBridge.METHOD_MARK_READ, mapOf("messageId" to EVACUATION.messageId))

        assertEquals(listOf("success:null"), marked.calls)
        assertEquals(1, unreadCount())
        assertEquals(true, getAll().single { it["messageId"] == EVACUATION.messageId }["read"])
    }

    @Test
    fun `the first reading of a notice goes to the receipt seam, once`() {
        notices.insertIfAbsent(SHELTER_OPEN)
        now += 5 * 60_000L

        call(AdminNoticeBridge.METHOD_MARK_READ, mapOf("messageId" to SHELTER_OPEN.messageId))
        call(AdminNoticeBridge.METHOD_MARK_READ, mapOf("messageId" to SHELTER_OPEN.messageId))

        assertEquals(listOf(SHELTER_OPEN.messageId), firstReads.map { it.messageId })
        assertEquals(now, firstReads.single().readAtMs)
        assertEquals(AdminNoticeKind.TARGETED, firstReads.single().kind)
    }

    @Test
    fun `marking a notice that is gone is fine`() {
        val marked = call(AdminNoticeBridge.METHOD_MARK_READ, mapOf("messageId" to "ffffffffffffffff"))

        assertEquals(listOf("success:null"), marked.calls)
        assertEquals(emptyList<StoredAdminNotice>(), firstReads)
    }

    @Test
    fun `markRead without a usable messageId is refused`() {
        notices.insertIfAbsent(EVACUATION)
        for (arguments in listOf(null, emptyMap<String, Any?>(), mapOf("messageId" to ""), mapOf("messageId" to 42), EVACUATION.messageId)) {
            val result = call(AdminNoticeBridge.METHOD_MARK_READ, arguments)

            assertEquals("$arguments", listOf("error:$INVALID_ARGUMENT"), result.calls)
        }
        assertEquals(1, unreadCount())
    }

    @Test
    fun `a notice stored while Flutter listens is pushed with the whole list`() {
        events.onListen(null, sink)
        notices.insertIfAbsent(EVACUATION)
        assertEquals(listOf(mapOf("type" to "admin_notice", "notices" to listOf(EVACUATION_MAP))), deliverPending())

        notices.insertIfAbsent(SHELTER_OPEN)
        assertEquals(
            listOf(mapOf("type" to "admin_notice", "notices" to listOf(SHELTER_OPEN_MAP, EVACUATION_MAP))),
            deliverPending()
        )
    }

    @Test
    fun `marking a notice read pushes the list with it read`() {
        events.onListen(null, sink)
        notices.insertIfAbsent(EVACUATION)
        deliverPending()

        call(AdminNoticeBridge.METHOD_MARK_READ, mapOf("messageId" to EVACUATION.messageId))

        assertEquals(
            listOf(mapOf("type" to "admin_notice", "notices" to listOf(EVACUATION_MAP + ("read" to true)))),
            deliverPending()
        )
    }

    @Test
    fun `once the engine is gone nothing more is pushed`() {
        events.onListen(null, sink)

        bridge.destroy()
        notices.insertIfAbsent(EVACUATION)

        assertEquals(emptyList<Any?>(), deliverPending())
    }

    @Test
    fun `a notice store that cannot be opened is NOTICE_STORE_UNAVAILABLE`() {
        val broken = AdminNoticeBridge(
            keyStore = { error("unused") },
            notices = EncryptedAdminNoticeStore(openPrefs = { throw GeneralSecurityException("keystore is gone") }, nowMs = { now }),
            notifier = RecordingAdminNoticeNotifier(),
            events = events,
            scope = CoroutineScope(dispatcher + Job()),
            storeDispatcher = dispatcher
        )
        for ((method, arguments) in listOf(
            AdminNoticeBridge.METHOD_GET_ALL to null,
            AdminNoticeBridge.METHOD_MARK_READ to mapOf("messageId" to EVACUATION.messageId)
        )) {
            assertEquals(method, listOf("error:${AdminNoticeBridge.ERROR_NOTICE_STORE_UNAVAILABLE}"), call(method, arguments, broken).calls)
        }
    }

    private companion object {
        const val DAY = 24 * 3_600_000L

        /** 2026-10-22T00:00:00Z, as the spec's test vectors. */
        const val ISSUED_AT = 1_792_627_200_000L

        val EVACUATION = StoredAdminNotice(
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

        val SHELTER_OPEN = StoredAdminNotice(
            messageId = "0f1e2d3c4b5a6978",
            kind = AdminNoticeKind.TARGETED,
            level = AdminNoticeLevel.INFO,
            issuedAtMs = ISSUED_AT + 60_000L,
            expiresAtMs = ISSUED_AT + 3_600_000L,
            replaces = null,
            content = "救援約 10 分鐘內抵達，請留在原地",
            status = AdminNoticeStatus.ACTIVE,
            receivedAtMs = ISSUED_AT + 60_000L
        )

        /** What Dart reads for [EVACUATION]: the wire names, independent of the Kotlin enums. */
        val EVACUATION_MAP = mapOf(
            "messageId" to "a1b2c3d4e5f60718",
            "kind" to "broadcast",
            "level" to "urgent",
            "content" to "土石流警戒：請立即撤離至大同國小避難所",
            "issuedAt" to 1_792_627_200_000L,
            "expiresAt" to 1_792_648_800_000L,
            "status" to "active",
            "replacedBy" to null,
            "read" to false
        )

        val SHELTER_OPEN_MAP = mapOf(
            "messageId" to "0f1e2d3c4b5a6978",
            "kind" to "targeted",
            "level" to "info",
            "content" to "救援約 10 分鐘內抵達，請留在原地",
            "issuedAt" to 1_792_627_260_000L,
            "expiresAt" to 1_792_630_800_000L,
            "status" to "active",
            "replacedBy" to null,
            "read" to false
        )
    }
}
