package com.bitchat.android.gateway

import android.os.Build
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.doReturn
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The listener's Android wiring lives exactly as long as the mesh service (#136), like the
 * outbound Gateway's: start() follows FirebaseAuth's sign-in state, stop() removes the sign-in
 * listener and the Firestore listener, so a restarted service never leaks or doubles them.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class AdminNoticeListenerRuntimeTest {

    private val auth = mock<FirebaseAuth>()
    private val listens = mutableListOf<Long>()
    private var active = 0
    private val feed = object : AdminNoticeFeed {
        override fun listen(sinceMs: Long, events: AdminNoticeFeed.Events): AdminNoticeFeed.Registration {
            listens += sinceMs
            active++
            return AdminNoticeFeed.Registration { active-- }
        }
    }
    private val subscription = AdminNoticeSubscription(
        feed = feed,
        scheduler = { _, _ -> {} },
        nowMs = { 1_800_000_000_000L },
        deliver = {}
    )

    @Test
    fun `the listener follows the account FirebaseAuth reports`() {
        var released = false
        val runtime = AdminNoticeListenerRuntime(auth, subscription, onStopped = { released = true })
        runtime.start()
        val authListener = argumentCaptor<FirebaseAuth.AuthStateListener>()
            .apply { verify(auth).addAuthStateListener(capture()) }
            .firstValue

        whenever(auth.currentUser).thenReturn(null)
        authListener.onAuthStateChanged(auth)
        assertTrue("signed out: nothing attached", listens.isEmpty())

        val user = mock<FirebaseUser> { on { uid } doReturn "uid-a" }
        whenever(auth.currentUser).thenReturn(user)
        authListener.onAuthStateChanged(auth)
        assertEquals(listOf(1_800_000_000_000L), listens)
        assertEquals(1, active)

        runtime.stop()

        verify(auth).removeAuthStateListener(authListener)
        assertEquals("the Firestore listener is removed", 0, active)
        assertTrue(released)
        authListener.onAuthStateChanged(auth)
        assertEquals("stopped for good", 1, listens.size)
        assertFalse(active > 0)
    }
}
