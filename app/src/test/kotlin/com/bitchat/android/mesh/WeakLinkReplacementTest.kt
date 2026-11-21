package com.bitchat.android.mesh

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WeakLinkReplacementTest {

    private var now = 1_000_000L
    private val replacement = WeakLinkReplacement(clock = { now })

    @Test
    fun `a candidate 10 dB stronger than the weakest link replaces it`() {
        assertTrue(replacement.shouldReplace(candidateRssi = -80, weakestRssi = -90))
    }

    @Test
    fun `a candidate less than 10 dB stronger does not`() {
        assertFalse(replacement.shouldReplace(candidateRssi = -81, weakestRssi = -90))
    }

    @Test
    fun `a link of unknown strength is never replaced on a guess`() {
        assertFalse(replacement.shouldReplace(candidateRssi = -40, weakestRssi = null))
    }

    @Test
    fun `replacements are at least 30 s apart`() {
        assertTrue(replacement.shouldReplace(-60, -90))

        now += 29_999
        assertFalse(replacement.shouldReplace(-60, -90))

        now += 1
        assertTrue(replacement.shouldReplace(-60, -90))
    }

    @Test
    fun `a refused candidate does not start the interval`() {
        assertFalse(replacement.shouldReplace(-85, -90))
        assertTrue(replacement.shouldReplace(-60, -90))
    }
}
