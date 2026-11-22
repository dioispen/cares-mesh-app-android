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
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.security.GeneralSecurityException
import java.util.UUID

/**
 * `adminNotice_getPublicKey` / `adminNotice_clearKey` (#140, docs/ADMIN_NOTICE_V1.md 收件者加密金鑰).
 * Signing out and emergency clear call clearKey: the private key goes, and with it every targeted
 * notice this device decrypted for the account, from the store and the notification shade.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class AdminNoticeBridgeTest {

    private val dispatcher = StandardTestDispatcher()
    private val storage: SharedPreferences = RuntimeEnvironment.getApplication()
        .getSharedPreferences("admin-notice-bridge-${UUID.randomUUID()}", Context.MODE_PRIVATE)
    private val store = AdminNoticeRecipientKeyStore(storage)

    /**
     * The notice list (#142) is [AdminNoticeBridgeNoticeListTest]'s; here only what clearKey deletes
     * from it. Writes fail while [noticesWritable] is false, as with a full disk.
     */
    private val noticePrefs: SharedPreferences = RuntimeEnvironment.getApplication()
        .getSharedPreferences("admin-notice-list-${UUID.randomUUID()}", Context.MODE_PRIVATE)
    private var noticesWritable = true
    private val gatedNoticePrefs = object : SharedPreferences by noticePrefs {
        override fun edit(): SharedPreferences.Editor = noticePrefs.edit().let { editor ->
            if (noticesWritable) editor else object : SharedPreferences.Editor by editor {
                override fun commit() = false
            }
        }
    }
    private val notices = EncryptedAdminNoticeStore(openPrefs = { gatedNoticePrefs }, nowMs = { NOW })
    private val notifications = RecordingAdminNoticeNotifier()
    private val poster = ManualPoster()
    private val events = BridgeEventEmitter(postToMain = poster, logDropped = {})
    private val sink = RecordingSink()
    private val bridge = AdminNoticeBridge(
        keyStore = { store },
        notices = notices,
        notifier = notifications,
        events = events,
        scope = CoroutineScope(dispatcher + Job()),
        storeDispatcher = dispatcher
    )

    private fun call(method: String, arguments: Any? = null): RecordingResult {
        val result = RecordingResult()
        assertTrue("$method is claimed", bridge.handle(MethodCall(method, arguments), result))
        dispatcher.scheduler.advanceUntilIdle()
        return result
    }

    private fun publicKeyFor(uid: String): ByteArray {
        val result = call(AdminNoticeBridge.METHOD_GET_PUBLIC_KEY, mapOf("uid" to uid))
        assertEquals(1, result.calls.size)
        return result.values.single() as ByteArray
    }

    @Test
    fun `the same uid asking again gets the same public key`() {
        val first = publicKeyFor("uid-alice")
        val again = publicKeyFor("uid-alice")

        assertEquals(32, first.size)
        assertArrayEquals(first, again)
    }

    @Test
    fun `another uid gets a new public key, and the old private key is deleted`() {
        val alice = publicKeyFor("uid-alice")
        val aliceOnDisk = storage.all.values.toSet()
        val aliceAgreed = store.agree(SENDER_EPHEMERAL)

        val bob = publicKeyFor("uid-bob")

        assertFalse(alice.contentEquals(bob))
        assertEquals("nothing of Alice's pair is left on disk", emptySet<Any?>(), storage.all.values.toSet().intersect(aliceOnDisk))
        assertFalse("Alice's notices no longer open here", aliceAgreed.contentEquals(store.agree(SENDER_EPHEMERAL)))
    }

    @Test
    fun `after clearKey the next request gets a new public key`() {
        val before = publicKeyFor("uid-alice")

        val cleared = call(AdminNoticeBridge.METHOD_CLEAR_KEY)
        val after = publicKeyFor("uid-alice")

        assertEquals(listOf("success:null"), cleared.calls)
        assertFalse(before.contentEquals(after))
    }

    @Test
    fun `clearKey deletes the private key, so nothing opens here until the next sign-in`() {
        publicKeyFor("uid-alice")

        call(AdminNoticeBridge.METHOD_CLEAR_KEY)

        assertNull(store.agree(SENDER_EPHEMERAL))
        assertEquals(emptyMap<String, Any?>(), storage.all)
    }

    @Test
    fun `clearKey without a key is fine`() {
        assertEquals(listOf("success:null"), call(AdminNoticeBridge.METHOD_CLEAR_KEY).calls)
    }

    // ── 登出與緊急清除：定向公告跟著私鑰一起刪除 ──────────────────────────────────

    @Test
    fun `clearKey deletes the targeted notices and their notifications, keeping the broadcasts`() {
        notices.insertIfAbsent(BROADCAST)
        notices.insertIfAbsent(TARGETED)

        val cleared = call(AdminNoticeBridge.METHOD_CLEAR_KEY)

        assertEquals(listOf("success:null"), cleared.calls)
        assertEquals(listOf(BROADCAST.messageId), notices.all().map { it.messageId })
        assertEquals(listOf(TARGETED.messageId), notifications.cancelled)
    }

    @Test
    fun `an open notice list is pushed without the targeted notices`() {
        notices.insertIfAbsent(BROADCAST)
        notices.insertIfAbsent(TARGETED)
        // What those two inserts pushed went out before Flutter listened.
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        events.onListen(null, sink)

        call(AdminNoticeBridge.METHOD_CLEAR_KEY)
        poster.runAll()

        val pushed = sink.events.single() as Map<*, *>
        assertEquals("admin_notice", pushed["type"])
        assertEquals(listOf(BROADCAST.messageId), (pushed["notices"] as List<*>).map { (it as Map<*, *>)["messageId"] })
    }

    @Test
    fun `a notice store that cannot be written fails clearKey, the key gone all the same, and a retry finishes`() {
        // Emergency clear stops on the failure and lets the user try again.
        publicKeyFor("uid-alice")
        notices.insertIfAbsent(TARGETED)
        noticesWritable = false

        val failed = call(AdminNoticeBridge.METHOD_CLEAR_KEY)

        assertEquals(listOf("error:${AdminNoticeBridge.ERROR_NOTICE_STORE_UNAVAILABLE}"), failed.calls)
        assertNull(store.agree(SENDER_EPHEMERAL))
        assertEquals(listOf(TARGETED.messageId), notices.all().map { it.messageId })

        noticesWritable = true
        val retried = call(AdminNoticeBridge.METHOD_CLEAR_KEY)

        assertEquals(listOf("success:null"), retried.calls)
        assertEquals(emptyList<StoredAdminNotice>(), notices.all())
        assertEquals(listOf(TARGETED.messageId), notifications.cancelled)
    }

    @Test
    fun `a key store that cannot be opened still lets clearKey delete the targeted notices`() {
        // Sign-out goes on when clearKey fails; the next account must not find them either way.
        notices.insertIfAbsent(BROADCAST)
        notices.insertIfAbsent(TARGETED)
        val broken = AdminNoticeBridge(
            keyStore = { throw GeneralSecurityException("keystore is gone") },
            notices = notices,
            notifier = notifications,
            events = events,
            scope = CoroutineScope(dispatcher + Job()),
            storeDispatcher = dispatcher
        )
        val result = RecordingResult()

        assertTrue(broken.handle(MethodCall(AdminNoticeBridge.METHOD_CLEAR_KEY, null), result))
        dispatcher.scheduler.advanceUntilIdle()

        assertEquals(listOf("error:${AdminNoticeBridge.ERROR_KEY_STORE_UNAVAILABLE}"), result.calls)
        assertEquals(listOf(BROADCAST.messageId), notices.all().map { it.messageId })
        assertEquals(listOf(TARGETED.messageId), notifications.cancelled)
    }

    @Test
    fun `getPublicKey without a usable uid is refused and generates nothing`() {
        for (arguments in listOf(null, emptyMap<String, Any?>(), mapOf("uid" to ""), mapOf("uid" to 42), "uid-alice")) {
            val result = call(AdminNoticeBridge.METHOD_GET_PUBLIC_KEY, arguments)

            assertEquals("$arguments", listOf("error:$INVALID_ARGUMENT"), result.calls)
        }
        assertNull(store.publicKey())
    }

    @Test
    fun `a key store that cannot be opened is KEY_STORE_UNAVAILABLE`() {
        val broken = AdminNoticeBridge(
            keyStore = { throw GeneralSecurityException("keystore is gone") },
            notices = notices,
            notifier = notifications,
            events = events,
            scope = CoroutineScope(dispatcher + Job()),
            storeDispatcher = dispatcher
        )
        for ((method, arguments) in listOf(
            AdminNoticeBridge.METHOD_GET_PUBLIC_KEY to mapOf("uid" to "uid-alice"),
            AdminNoticeBridge.METHOD_CLEAR_KEY to null
        )) {
            val result = RecordingResult()
            assertTrue(broken.handle(MethodCall(method, arguments), result))
            dispatcher.scheduler.advanceUntilIdle()

            assertEquals(method, listOf("error:${AdminNoticeBridge.ERROR_KEY_STORE_UNAVAILABLE}"), result.calls)
        }
    }

    @Test
    fun `methods it does not own are left to the next handler`() {
        val result = RecordingResult()

        assertFalse(bridge.handle(MethodCall("settings_getState", null), result))
        assertEquals(emptyList<String>(), result.calls)
    }

    private companion object {
        /** 2026-10-22T00:00:00Z, as the spec's test vectors. */
        const val ISSUED_AT = 1_792_627_200_000L
        const val NOW = ISSUED_AT + 60_000L

        /** Any valid X25519 public key standing in for a targeted Admin Notice's ephemeral key. */
        val SENDER_EPHEMERAL = ByteArray(32) { 9 }

        val BROADCAST = StoredAdminNotice(
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

        val TARGETED = StoredAdminNotice(
            messageId = "0f1e2d3c4b5a6978",
            kind = AdminNoticeKind.TARGETED,
            level = AdminNoticeLevel.INFO,
            issuedAtMs = ISSUED_AT + 30_000L,
            expiresAtMs = ISSUED_AT + 3_600_000L,
            replaces = null,
            content = "救援約 10 分鐘內抵達，請留在原地",
            status = AdminNoticeStatus.ACTIVE,
            receivedAtMs = ISSUED_AT + 30_000L
        )
    }
}
