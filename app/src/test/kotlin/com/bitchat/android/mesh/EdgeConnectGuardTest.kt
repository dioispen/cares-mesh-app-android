package com.bitchat.android.mesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EdgeConnectGuardTest {

    private var now = 1_000_000L
    private val guard = EdgeConnectGuard(clock = { now })

    @Test
    fun `weak candidates get a 10 s timeout, others a longer one than the stack's`() {
        assertEquals(10_000L, guard.begin(ADDRESS, -96)!!.timeoutMs)
        assertEquals(35_000L, guard.begin(OTHER, -95)!!.timeoutMs)
    }

    @Test
    fun `no second attempt to an address while one is in flight`() {
        val attempt = guard.begin(ADDRESS, -70)
        assertNotNull(attempt)

        // MeshConnectionTracker lets a pending entry expire after 10 s; the stack may still be trying.
        now += 30_000
        assertFalse(guard.mayAttempt(ADDRESS, -70))
        assertNull(guard.begin(ADDRESS, -70))
        assertTrue("other addresses are unaffected", guard.mayAttempt(OTHER, -70))

        guard.onEnded(attempt!!)
        assertTrue(guard.mayAttempt(ADDRESS, -70))
    }

    @Test
    fun `a weak attempt still connecting at its timeout is cancelled and backs off 15 s`() {
        val attempt = guard.begin(ADDRESS, -100)!!

        now += attempt.timeoutMs
        assertTrue("caller must cancel it", guard.onTimeout(attempt))

        assertEquals(15_000L, guard.backoffRemainingMs(ADDRESS))
        assertFalse(guard.mayAttempt(ADDRESS, -100))
        now += 15_000
        assertTrue(guard.mayAttempt(ADDRESS, -100))
    }

    @Test
    fun `backoff grows 15 s, 30 s, 60 s and stays at 60 s`() {
        for (expected in listOf(15_000L, 30_000L, 60_000L, 60_000L)) {
            val attempt = guard.begin(ADDRESS, -101)!!
            guard.onEnded(attempt) // e.g. status 133 before the link came up
            assertEquals(expected, guard.backoffRemainingMs(ADDRESS))
            now += expected
        }
    }

    @Test
    fun `a successful link clears the backoff`() {
        guard.onEnded(guard.begin(ADDRESS, -101)!!)
        now += 15_000
        guard.onEnded(guard.begin(ADDRESS, -101)!!)
        now += 30_000

        val attempt = guard.begin(ADDRESS, -99)!!
        assertTrue(guard.onLinkReady(attempt))
        guard.onEnded(attempt) // the link goes down later: not a failed attempt

        assertEquals(0L, guard.backoffRemainingMs(ADDRESS))
        guard.onEnded(guard.begin(ADDRESS, -101)!!)
        assertEquals("starts over at the first step", 15_000L, guard.backoffRemainingMs(ADDRESS))
    }

    @Test
    fun `hearing the peer 10 dB stronger than at the failure clears the backoff`() {
        guard.onEnded(guard.begin(ADDRESS, -100)!!)

        assertFalse(guard.mayAttempt(ADDRESS, -91))
        assertTrue(guard.mayAttempt(ADDRESS, -90))
        assertEquals(0L, guard.backoffRemainingMs(ADDRESS))
    }

    @Test
    fun `failed attempts that were not weak do not back off here`() {
        guard.onEnded(guard.begin(ADDRESS, -80)!!)

        assertTrue(guard.mayAttempt(ADDRESS, -80))
        assertEquals(0L, guard.backoffRemainingMs(ADDRESS))
    }

    @Test
    fun `a link that comes up after its timeout is not used`() {
        val attempt = guard.begin(ADDRESS, -100)!!
        assertTrue(guard.onTimeout(attempt))

        assertFalse(guard.onLinkReady(attempt))
    }

    @Test
    fun `a timeout after the link came up or ended does nothing`() {
        val ready = guard.begin(ADDRESS, -100)!!
        guard.onLinkReady(ready)
        assertFalse(guard.onTimeout(ready))

        val failed = guard.begin(OTHER, -100)!!
        guard.onEnded(failed)
        val backoff = guard.backoffRemainingMs(OTHER)
        assertFalse(guard.onTimeout(failed))
        assertEquals("not counted twice", backoff, guard.backoffRemainingMs(OTHER))
    }

    private companion object {
        const val ADDRESS = "AA:BB:CC:DD:EE:01"
        const val OTHER = "AA:BB:CC:DD:EE:02"
    }
}
