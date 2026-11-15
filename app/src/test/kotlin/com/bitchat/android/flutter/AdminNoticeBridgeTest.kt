package com.bitchat.android.flutter

import android.content.Context
import android.content.SharedPreferences
import com.bitchat.android.adminnotice.EncryptedAdminNoticeStore
import com.bitchat.android.identity.AdminNoticeRecipientKeyStore
import com.bitchat.android.testsupport.RecordingResult
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

/** `adminNotice_getPublicKey` / `adminNotice_clearKey` (#140, docs/ADMIN_NOTICE_V1.md 收件者加密金鑰). */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class AdminNoticeBridgeTest {

    private val dispatcher = StandardTestDispatcher()
    private val storage: SharedPreferences = RuntimeEnvironment.getApplication()
        .getSharedPreferences("admin-notice-bridge-${UUID.randomUUID()}", Context.MODE_PRIVATE)
    private val store = AdminNoticeRecipientKeyStore(storage)

    /** The notice list (#142) is [AdminNoticeBridgeNoticeListTest]'s; here it only has to exist. */
    private val notices = EncryptedAdminNoticeStore(
        openPrefs = {
            RuntimeEnvironment.getApplication()
                .getSharedPreferences("admin-notice-list-${UUID.randomUUID()}", Context.MODE_PRIVATE)
        },
        nowMs = System::currentTimeMillis
    )
    private val events = BridgeEventEmitter(postToMain = {}, logDropped = {})
    private val bridge = AdminNoticeBridge(
        keyStore = { store },
        notices = notices,
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
        /** Any valid X25519 public key standing in for a targeted Admin Notice's ephemeral key. */
        val SENDER_EPHEMERAL = ByteArray(32) { 9 }
    }
}
