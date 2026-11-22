package com.bitchat.android.mesh

/**
 * Whether a full phone gives up its weakest link for a clearly stronger candidate (P1-5, ADR-0013).
 *
 * Upstream never connected once the connection limit was reached, and evicted the oldest link
 * when over it. Near capacity the RSSI threshold is strict ([ConnectionRssiThreshold]), so a full
 * phone could keep a link at the edge of range while a peer standing next to it was turned away.
 * A candidate at least [MARGIN_DB] stronger than the weakest link now takes its place, at most
 * once per [MIN_INTERVAL_MS] so that two candidates of similar strength cannot make the links
 * churn. A link whose strength is unknown is never replaced on a guess.
 */
internal class WeakLinkReplacement(
    private val clock: () -> Long = System::currentTimeMillis,
    private val marginDb: Int = MARGIN_DB,
    private val minIntervalMs: Long = MIN_INTERVAL_MS
) {
    private var lastReplacementAtMs: Long? = null

    /**
     * True when a candidate heard at [candidateRssi] should replace the weakest link, last heard at
     * [weakestRssi] (null: unknown). Saying yes starts the next [minIntervalMs].
     */
    @Synchronized
    fun shouldReplace(candidateRssi: Int, weakestRssi: Int?): Boolean {
        if (weakestRssi == null) return false
        if (candidateRssi - weakestRssi < marginDb) return false
        val now = clock()
        val last = lastReplacementAtMs
        if (last != null && now - last < minIntervalMs) return false
        lastReplacementAtMs = now
        return true
    }

    companion object {
        /** The candidate must be at least this much stronger than the weakest link (dB). */
        const val MARGIN_DB = 10

        /** At most one replacement per this interval. */
        const val MIN_INTERVAL_MS = 30_000L
    }
}
