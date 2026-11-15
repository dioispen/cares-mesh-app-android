package com.bitchat.android.gateway

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Gateway's Firestore listener on `admin_notices` (#136, 「Gateway：從 Firestore 注入 mesh」):
 * attached while signed in, never retried at once after an error. Firestore, the retry scheduler
 * and the clock are fakes; time only moves when the test says so.
 */
class AdminNoticeSubscriptionTest {

    private val clock = FakeClock(start = 1_800_000_000_000L)
    private val feed = FakeFeed()
    private val delivered = mutableListOf<ByteArray>()
    private val subscription = AdminNoticeSubscription(feed, clock, nowMs = { clock.now }, deliver = { delivered += it })

    // ── 登入狀態 ───────────────────────────────────────────────────────────

    @Test
    fun `nothing is attached while signed out`() {
        subscription.onSignedIn(null)

        assertTrue(feed.listens.isEmpty())
    }

    @Test
    fun `signing in attaches a listener for notices expiring after now`() {
        subscription.onSignedIn("uid-a")

        assertEquals(listOf(clock.now), feed.listens.map { it.sinceMs })
        assertTrue(feed.latest.active)
    }

    @Test
    fun `signing out detaches the listener`() {
        subscription.onSignedIn("uid-a")

        subscription.onSignedIn(null)

        assertFalse(feed.latest.active)
        assertEquals(1, feed.listens.size)
    }

    @Test
    fun `another account signing in re-attaches from the time it signed in`() {
        subscription.onSignedIn("uid-a")
        val first = feed.latest
        clock.advance(5 * MINUTE)

        subscription.onSignedIn("uid-b")

        assertFalse(first.active)
        assertTrue(feed.latest.active)
        assertEquals(clock.now, feed.latest.sinceMs)
    }

    @Test
    fun `the same account reported again keeps its listener`() {
        subscription.onSignedIn("uid-a")

        subscription.onSignedIn("uid-a")

        assertEquals(1, feed.listens.size)
        assertTrue(feed.latest.active)
    }

    // ── 收到文件 ───────────────────────────────────────────────────────────

    @Test
    fun `added documents are handed over, also from the local cache`() {
        subscription.onSignedIn("uid-a")

        feed.latest.added(listOf(byteArrayOf(1)), fromCache = true)
        feed.latest.added(listOf(byteArrayOf(2), byteArrayOf(3)), fromCache = false)

        assertEquals(listOf(1, 2, 3), delivered.map { it.single().toInt() })
    }

    @Test
    fun `a detached listener hands over nothing it still reports`() {
        subscription.onSignedIn("uid-a")
        val old = feed.latest
        subscription.onSignedIn(null)

        old.added(listOf(byteArrayOf(1)), fromCache = false)

        assertTrue(delivered.isEmpty())
    }

    // ── 錯誤處理 ───────────────────────────────────────────────────────────

    @Test
    fun `after RESOURCE_EXHAUSTED or UNAVAILABLE it waits a minute, never retrying at once`() {
        subscription.onSignedIn("uid-a")

        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)

        assertFalse(feed.latest.active)
        assertEquals(1, feed.listens.size)
        clock.advance(MINUTE - 1)
        assertEquals(1, feed.listens.size)
        clock.advance(1)
        assertEquals(2, feed.listens.size)
        assertEquals("re-attached from the time of the retry", clock.now, feed.latest.sinceMs)
    }

    @Test
    fun `the wait doubles after each failure up to thirty minutes`() {
        subscription.onSignedIn("uid-a")

        val waits = (1..7).map {
            feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)
            waitForNextListen()
        }

        assertEquals(listOf(1L, 2L, 4L, 8L, 16L, 30L, 30L).map { it * MINUTE }, waits)
    }

    @Test
    fun `reaching the server resets the wait, a snapshot from the cache does not`() {
        subscription.onSignedIn("uid-a")
        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)
        waitForNextListen()
        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)
        waitForNextListen()

        feed.latest.added(emptyList(), fromCache = true)
        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)
        assertEquals(4 * MINUTE, waitForNextListen())

        feed.latest.added(emptyList(), fromCache = false)
        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)
        assertEquals(MINUTE, waitForNextListen())
    }

    @Test
    fun `after PERMISSION_DENIED it stays detached until the sign-in state changes`() {
        subscription.onSignedIn("uid-a")

        feed.latest.failed(AdminNoticeFeed.Error.PERMISSION_DENIED)
        clock.advance(24 * 60 * MINUTE)
        subscription.onSignedIn("uid-a")

        assertEquals(1, feed.listens.size)

        subscription.onSignedIn(null)
        subscription.onSignedIn("uid-a")

        assertEquals(2, feed.listens.size)
        assertTrue(feed.latest.active)
    }

    @Test
    fun `signing out while waiting cancels the retry, and signing in again attaches at once`() {
        subscription.onSignedIn("uid-a")
        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)

        subscription.onSignedIn(null)
        clock.advance(60 * MINUTE)
        assertEquals(1, feed.listens.size)

        subscription.onSignedIn("uid-a")
        assertEquals(2, feed.listens.size)
        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)
        assertEquals("a new sign-in starts the wait over", MINUTE, waitForNextListen())
    }

    // ── 服務停止 ───────────────────────────────────────────────────────────

    @Test
    fun `stopping detaches the listener and cancels a pending retry`() {
        subscription.onSignedIn("uid-a")
        val attached = feed.latest

        subscription.stop()

        assertFalse(attached.active)
        attached.added(listOf(byteArrayOf(1)), fromCache = false)
        assertTrue(delivered.isEmpty())
    }

    @Test
    fun `a stopped subscription neither retries nor follows sign-ins`() {
        subscription.onSignedIn("uid-a")
        feed.latest.failed(AdminNoticeFeed.Error.RETRYABLE)

        subscription.stop()
        clock.advance(60 * MINUTE)
        subscription.onSignedIn("uid-b")

        assertEquals(1, feed.listens.size)
    }

    @Test
    fun `the wire is handed over byte for byte`() {
        subscription.onSignedIn("uid-a")
        val wire = byteArrayOf(0x01, 0x01, 0x01, 0x03)

        feed.latest.added(listOf(wire), fromCache = false)

        assertArrayEquals(wire, delivered.single())
    }

    /** Advances the clock minute by minute until the subscription listens again; returns the wait. */
    private fun waitForNextListen(): Long {
        val listensBefore = feed.listens.size
        val start = clock.now
        while (feed.listens.size == listensBefore) {
            clock.advance(MINUTE)
            check(clock.now - start <= 24 * 60 * MINUTE) { "never re-attached" }
        }
        return clock.now - start
    }

    private class FakeFeed : AdminNoticeFeed {
        val listens = mutableListOf<Listen>()
        val latest: Listen get() = listens.last()

        override fun listen(sinceMs: Long, events: AdminNoticeFeed.Events): AdminNoticeFeed.Registration =
            Listen(sinceMs, events).also { listens += it }

        class Listen(val sinceMs: Long, private val events: AdminNoticeFeed.Events) : AdminNoticeFeed.Registration {
            var active = true
                private set

            /** Firestore ends a listener that reports an error. */
            fun failed(error: AdminNoticeFeed.Error) {
                active = false
                events.onError(error)
            }

            fun added(wires: List<ByteArray>, fromCache: Boolean) = events.onAdded(wires, fromCache)

            override fun remove() {
                active = false
            }
        }
    }

    /** A scheduler on a fake clock: actions run when [advance] passes their time. */
    private class FakeClock(start: Long) : AdminNoticeSubscription.Scheduler {
        var now = start
            private set
        private val pending = mutableListOf<Pair<Long, () -> Unit>>()

        override fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
            val entry = (now + delayMs) to action
            pending += entry
            return { pending.remove(entry) }
        }

        fun advance(ms: Long) {
            now += ms
            while (true) {
                val due = pending.filter { it.first <= now }.minByOrNull { it.first } ?: break
                pending.remove(due)
                due.second()
            }
        }
    }

    private companion object {
        const val MINUTE = 60_000L
    }
}
