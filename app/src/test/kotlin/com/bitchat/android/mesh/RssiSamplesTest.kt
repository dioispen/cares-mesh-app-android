package com.bitchat.android.mesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RssiSamplesTest {

    private var now = 10_000_000L
    private val samples = RssiSamples(clock = { now })

    @Test
    fun `a scan is kept by address and by the peer in its service data`() {
        samples.record("A", "peer", -70)

        assertEquals(RssiSamples.Sample(-70, now), samples.byAddress("A"))
        assertEquals(RssiSamples.Sample(-70, now), samples.byPeer("peer"))
    }

    @Test
    fun `freshest picks the latest sample and the first one on a tie`() {
        val old = RssiSamples.Sample(-60, 1)
        val new = RssiSamples.Sample(-90, 2)
        val tie = RssiSamples.Sample(-50, 2)

        assertEquals(new, RssiSamples.freshest(old, null, new))
        assertEquals(new, RssiSamples.freshest(new, tie))
        assertNull(RssiSamples.freshest(null, null))
    }

    @Test
    fun `old samples of rotated addresses are pruned once many have piled up`() {
        samples.record("old", "old-peer", -80)
        now += RssiSamples.PRUNE_OLDER_THAN_MS + 1
        repeat(RssiSamples.PRUNE_ABOVE_ADDRESSES) { samples.record("addr-$it", null, -70) }
        samples.record("trigger", "new-peer", -70)

        assertNull(samples.byAddress("old"))
        assertNull(samples.byPeer("old-peer"))
        assertEquals(-70, samples.byPeer("new-peer")?.rssi)
    }
}
