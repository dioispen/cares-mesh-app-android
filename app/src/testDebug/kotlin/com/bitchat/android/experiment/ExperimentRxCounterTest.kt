package com.bitchat.android.experiment

import org.junit.Assert.assertEquals
import org.junit.Test

/** The field screen's per-handle RX counts over the last 20 s and 60 s (#70). */
class ExperimentRxCounterTest {
    private var now = 0L
    private val counter = ExperimentRxCounter { now }

    @Test
    fun `counts arrivals per handle inside each window`() {
        counter.record("ee0000000001", 0)
        counter.record("ee0000000001", 30_000)
        counter.record("ee0000000002", 50_000)
        now = 60_000

        assertEquals(mapOf("ee0000000002" to 1), counter.countsWithin(20_000))
        assertEquals(mapOf("ee0000000001" to 1, "ee0000000002" to 1), counter.countsWithin(60_000))
    }

    @Test
    fun `an arrival exactly one window old has left it`() {
        counter.record("ee0000000001", 40_000)
        now = 60_000

        assertEquals(emptyMap<String, Int>(), counter.countsWithin(20_000))
        assertEquals(mapOf("ee0000000001" to 1), counter.countsWithin(60_000))
    }

    @Test
    fun `old arrivals are forgotten`() {
        counter.record("ee0000000001", 0)
        now = 61_000
        counter.record("ee0000000002", 61_000)

        assertEquals(mapOf("ee0000000002" to 1), counter.countsWithin(ExperimentRxCounter.MAX_WINDOW_MS))
        assertEquals(1, counter.size)
    }
}
