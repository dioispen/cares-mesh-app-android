package com.bitchat.android.mesh

import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthReportSigningKeyCacheTest {

    private val retentionMs = 2 * 60 * 60 * 1_000L
    private val cache = HealthReportSigningKeyCache(retentionMs = retentionMs, maxEntries = 3)
    private var now = 1_800_000_000_000L

    private val noiseKey = ByteArray(32) { 0x0B }
    private val signingKey = ByteArray(32) { 0x0A }
    private val otherSigningKey = ByteArray(32) { 0x0C }

    @Test
    fun `returns the key it learned`() {
        assertTrue(cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now))

        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_A, now))
    }

    @Test
    fun `knows nothing about a peer it never learned`() {
        assertNull(cache.signingKeyFor(PEER_A, now))
    }

    @Test
    fun `keeps the key until the retention period is over`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)

        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_A, now + retentionMs))
        assertNull(cache.signingKeyFor(PEER_A, now + retentionMs + 1))
    }

    @Test
    fun `learning the key again restarts its retention`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now + retentionMs)

        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_A, now + retentionMs + 1))
    }

    @Test
    fun `clear forgets every key`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)

        cache.clear()

        assertNull(cache.signingKeyFor(PEER_A, now))
    }

    @Test
    fun `evicts the key learned longest ago when over capacity`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)
        cache.remember(PEER_B, noiseKey, signingKey, announcement(PEER_B), now + 1)
        cache.remember(PEER_C, noiseKey, signingKey, announcement(PEER_C), now + 2)
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now + 3)

        cache.remember(PEER_D, noiseKey, signingKey, announcement(PEER_D), now + 4)

        assertNull(cache.signingKeyFor(PEER_B, now + 4))
        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_A, now + 4))
        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_C, now + 4))
        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_D, now + 4))
    }

    @Test
    fun `refuses an unauthenticated replacement key`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)

        assertFalse(cache.remember(PEER_A, noiseKey, otherSigningKey, announcement(PEER_A), now + 1))

        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_A, now + 1))
    }

    @Test
    fun `refuses a replacement Noise key`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)

        assertFalse(cache.remember(PEER_A, ByteArray(32) { 0x6B }, signingKey, announcement(PEER_A), now + 1))
    }

    @Test
    fun `accepts an authenticated replacement key`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)

        assertTrue(cache.remember(PEER_A, noiseKey, otherSigningKey, announcement(PEER_A), now + 1, authenticated = true))

        assertArrayEquals(otherSigningKey, cache.signingKeyFor(PEER_A, now + 1))
    }

    @Test
    fun `an expired key no longer blocks a different one`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)

        assertTrue(cache.remember(PEER_A, noiseKey, otherSigningKey, announcement(PEER_A), now + retentionMs + 1))
    }

    @Test
    fun `hands out copies so callers cannot alter the cached key`() {
        val learned = signingKey.copyOf()
        cache.remember(PEER_A, noiseKey, learned, announcement(PEER_A), now)
        learned.fill(0)
        cache.signingKeyFor(PEER_A, now)!!.fill(0)

        assertArrayEquals(signingKey, cache.signingKeyFor(PEER_A, now))
    }

    // The signed ANNOUNCE itself is kept so a relay can pass it on with the report (#95)

    @Test
    fun `keeps the announcement the key was learned from`() {
        val announcement = announcement(PEER_A)
        cache.remember(PEER_A, noiseKey, signingKey, announcement, now)

        assertEquals(announcement, cache.announcementFor(PEER_A, now))
    }

    @Test
    fun `keeps the newer announcement when the key is learned again from an older copy`() {
        val newer = announcement(PEER_A, timestamp = now - 1_000)
        cache.remember(PEER_A, noiseKey, signingKey, newer, now)
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A, timestamp = now - 60_000), now + 1)

        assertEquals(newer, cache.announcementFor(PEER_A, now + 1))
    }

    @Test
    fun `forgets the announcement together with the key`() {
        cache.remember(PEER_A, noiseKey, signingKey, announcement(PEER_A), now)

        assertNull(cache.announcementFor(PEER_A, now + retentionMs + 1))
        assertNull(cache.announcementFor(PEER_B, now))
    }

    private fun announcement(peerID: String, timestamp: Long = now - 30_000) = BitchatPacket(
        type = MessageType.ANNOUNCE.value,
        senderID = peerID.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
        timestamp = timestamp.toULong(),
        payload = byteArrayOf(1, 2, 3),
        signature = ByteArray(64) { 1 },
        ttl = 7u
    )

    private companion object {
        const val PEER_A = "a1a2a3a4a5a6a7a8"
        const val PEER_B = "b1b2b3b4b5b6b7b8"
        const val PEER_C = "c1c2c3c4c5c6c7c8"
        const val PEER_D = "d1d2d3d4d5d6d7d8"
    }
}
