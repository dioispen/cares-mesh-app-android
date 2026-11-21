package com.bitchat.android.mesh

/**
 * Keeps outbound connection attempts at the edge of range from tying up the controller (P1-5,
 * ADR-0011).
 *
 * [ConnectionRssiThreshold] lets the client try any advertisement it can hear. A
 * `connectGatt(autoConnect = false)` that cannot complete hangs in the stack for about 30 s before
 * it reports failure (often status 133), and a second `connectGatt` to the same address meanwhile
 * leaks a client interface. Upstream's strict threshold kept such attempts rare; this guard does
 * it now:
 *
 * 1. **One attempt per address in flight.** [begin] refuses while one is still connecting, however
 *    long ago the tracker's pending entry expired ([MeshConnectionTracker] lets a new attempt
 *    through after 10 s).
 * 2. **A timeout per attempt.** A weak candidate (scan RSSI below [WEAK_BELOW_DBM]) that has not
 *    connected and negotiated its MTU within [WEAK_ATTEMPT_TIMEOUT_MS] is cancelled by the caller.
 *    Any other attempt gets [ATTEMPT_TIMEOUT_MS], longer than the stack's own, which only catches a
 *    callback that never comes, so an address can never stay blocked.
 * 3. **Backoff after a failed weak attempt**, per address: [BACKOFF_STEPS_MS], the last step
 *    repeating. A successful link or hearing the peer [RESET_WHEN_STRONGER_BY_DB] stronger than at
 *    the failure clears it.
 *
 * Failed attempts that were not weak back off through [MeshConnectionTracker] as before.
 */
internal class EdgeConnectGuard(private val clock: () -> Long = System::currentTimeMillis) {

    /** One `connectGatt` call; the caller holds it until the attempt ends. */
    class Attempt internal constructor(val address: String, val rssi: Int, val timeoutMs: Long) {
        val isWeak: Boolean get() = rssi < WEAK_BELOW_DBM
        internal var linkReady = false
        internal var ended = false
    }

    private class AddressState {
        var inFlight: Attempt? = null
        var weakFailures = 0
        var backoffUntilMs = 0L
        var failedAtRssi = 0
    }

    private val states = HashMap<String, AddressState>()

    /** Whether an attempt to [address], heard now at [rssi], may start: none in flight, no backoff. */
    @Synchronized
    fun mayAttempt(address: String, rssi: Int): Boolean {
        val state = states[address] ?: return true
        if (state.inFlight != null) return false
        if (state.weakFailures == 0) return true
        if (rssi >= state.failedAtRssi + RESET_WHEN_STRONGER_BY_DB) {
            resetBackoff(address, state)
            return true
        }
        return clock() >= state.backoffUntilMs
    }

    /** Starts an attempt, or returns null when [mayAttempt] says no. */
    @Synchronized
    fun begin(address: String, rssi: Int): Attempt? {
        if (!mayAttempt(address, rssi)) return null
        val attempt = Attempt(address, rssi, if (rssi < WEAK_BELOW_DBM) WEAK_ATTEMPT_TIMEOUT_MS else ATTEMPT_TIMEOUT_MS)
        states.getOrPut(address) { AddressState() }.inFlight = attempt
        prune()
        return attempt
    }

    /**
     * The link is connected and its MTU negotiated. False when the attempt already ended (it timed
     * out and was cancelled): the caller must then drop this link instead of using it.
     */
    @Synchronized
    fun onLinkReady(attempt: Attempt): Boolean {
        if (attempt.ended) return false
        attempt.linkReady = true
        val state = states[attempt.address] ?: return true
        if (state.inFlight === attempt) state.inFlight = null
        resetBackoff(attempt.address, state)
        return true
    }

    /** The stack reported the attempt's GATT client disconnected, or `connectGatt` failed outright. */
    @Synchronized
    fun onEnded(attempt: Attempt) {
        if (attempt.ended) return
        attempt.ended = true
        if (!attempt.linkReady) recordFailure(attempt)
    }

    /**
     * The attempt's timeout elapsed. True when it is still connecting: the caller must cancel it
     * (`disconnect()` and `close()`) and clear its pending entry.
     */
    @Synchronized
    fun onTimeout(attempt: Attempt): Boolean {
        if (attempt.ended || attempt.linkReady) return false
        attempt.ended = true
        recordFailure(attempt)
        return true
    }

    /** Milliseconds until [address] may be tried again (0 when it may be now). For logs and tests. */
    @Synchronized
    fun backoffRemainingMs(address: String): Long =
        states[address]?.let { (it.backoffUntilMs - clock()).coerceAtLeast(0L) } ?: 0L

    private fun recordFailure(attempt: Attempt) {
        val state = states[attempt.address] ?: return
        if (state.inFlight === attempt) state.inFlight = null
        if (!attempt.isWeak) {
            if (state.weakFailures == 0) states.remove(attempt.address)
            return
        }
        state.weakFailures++
        state.failedAtRssi = attempt.rssi
        val step = BACKOFF_STEPS_MS[(state.weakFailures - 1).coerceAtMost(BACKOFF_STEPS_MS.lastIndex)]
        state.backoffUntilMs = clock() + step
    }

    private fun resetBackoff(address: String, state: AddressState) {
        state.weakFailures = 0
        state.backoffUntilMs = 0L
        if (state.inFlight == null) states.remove(address)
    }

    /** Advertising addresses rotate; forget backoffs that ended long ago once many have piled up. */
    private fun prune() {
        if (states.size <= PRUNE_ABOVE_ADDRESSES) return
        val now = clock()
        states.entries.removeIf { (_, state) ->
            state.inFlight == null && now - state.backoffUntilMs > PRUNE_BACKOFF_ENDED_MS
        }
    }

    companion object {
        /**
         * Below this scan RSSI an attempt counts as weak: about where the trial's links broke
         * (−93 to −99 dBm), so it may well never complete.
         */
        const val WEAK_BELOW_DBM = -95

        /** A weak attempt must be connected with its MTU negotiated within this. */
        const val WEAK_ATTEMPT_TIMEOUT_MS = 10_000L

        /** Any other attempt: longer than the stack's own ~30 s connect timeout. */
        const val ATTEMPT_TIMEOUT_MS = 35_000L

        /** Backoff after the 1st, 2nd, 3rd and later failed weak attempts to one address. */
        val BACKOFF_STEPS_MS = longArrayOf(15_000L, 30_000L, 60_000L)

        /** Hearing the peer this much stronger than at the failed attempt clears the backoff (dB). */
        const val RESET_WHEN_STRONGER_BY_DB = 10

        const val PRUNE_ABOVE_ADDRESSES = 128
        const val PRUNE_BACKOFF_ENDED_MS = 10 * 60_000L
    }
}
