package com.bitchat.android.mesh

/**
 * The weakest scan RSSI at which this phone still initiates a GATT connection to a peer (P1-5,
 * ADR-0013). A link that is already up is never dropped for being weak; it lives until the BLE
 * supervision timeout.
 *
 * Upstream bitchat (2025-07) used one strict value per power mode, tuned for crowded places where
 * weak neighbours would take up connection slots. The four-phone trial of 2026-11-18 showed the
 * opposite problem for a disaster scene: a link held to about 170 m, but reconnecting took walking
 * back to about 15 m (BALANCED, −85 dBm). Weak links proved reliable — direct delivery at −93 to
 * −99 dBm until 6 s before the break, edge-link PDR 96.9%, only 38 of 5772 losses caused by the link
 * itself — and the eight connection slots were never all used. So the threshold now depends on how
 * much this phone needs another link:
 *
 * 1. **Isolated** — fewer than [ISOLATED_BELOW_DIRECT_PEERS] distinct direct peers:
 *    [ANY_AUDIBLE_DBM] in every power mode. For an isolated phone, connecting is the only way its
 *    Health Report gets out, and a Rescuer often only passes by.
 * 2. **Near capacity** — at most [NEAR_CAPACITY_FREE_SLOTS] slot left: upstream's strict values, so
 *    the last slot goes to a strong neighbour. A clearly stronger candidate can still take a full
 *    phone's weakest link ([WeakLinkReplacement]). This tier is what protects crowded places.
 * 3. **Otherwise** — [ANY_AUDIBLE_DBM], except ULTRA_LOW_POWER (critical battery, and the phone
 *    already has peers to pass its reports on), which keeps [RELAXED_ULTRA_LOW_POWER_DBM].
 *
 * There is no longer a hysteresis gap between starting a link and losing it (about −95 to
 * −100 dBm). What that gap protected against — doomed attempts at the edge of range, which hang in
 * the stack for about 30 s — is handled by [EdgeConnectGuard] instead.
 *
 * Every number is a named constant so field tests (E5-C walk-in distance, E3 crowded slots, E4
 * battery) can tune them.
 */
internal object ConnectionRssiThreshold {

    /** Fewer distinct direct peers than this and the phone counts as isolated. */
    const val ISOLATED_BELOW_DIRECT_PEERS = 2

    /** Free connection slots at or below this count as near capacity (8 slots: from the 7th link on). */
    const val NEAR_CAPACITY_FREE_SLOTS = 1

    /**
     * "Connect to any advertisement we can hear": below the receive sensitivity of phone BLE
     * radios (roughly −100 to −106 dBm; −106 dBm was the weakest scan in the trial), so no scan
     * result is ever filtered out by strength.
     */
    const val ANY_AUDIBLE_DBM = -115

    // Near capacity: upstream bitchat's per-mode values (2025-07), unchanged.
    const val STRICT_PERFORMANCE_DBM = -95
    const val STRICT_BALANCED_DBM = -85
    const val STRICT_POWER_SAVER_DBM = -75
    const val STRICT_ULTRA_LOW_POWER_DBM = -65

    // Two or more peers and free slots.
    const val RELAXED_PERFORMANCE_DBM = ANY_AUDIBLE_DBM
    const val RELAXED_BALANCED_DBM = ANY_AUDIBLE_DBM
    const val RELAXED_POWER_SAVER_DBM = ANY_AUDIBLE_DBM

    /**
     * Critical battery with peers already linked: extra links only cost battery, so only fairly
     * solid ones (about where trial links stayed reliable) are started.
     */
    const val RELAXED_ULTRA_LOW_POWER_DBM = -95

    enum class Reason { ISOLATED, NEAR_CAPACITY, RELAXED }

    data class Decision(val dbm: Int, val reason: Reason)

    /**
     * @param directPeerCount distinct peers on this phone's current links, counted as
     *   [BluetoothConnectionTracker.getDirectPeerCount] does (peers, not links).
     * @param connectionCount current links, client and server.
     * @param maxConnections the overall connection limit.
     */
    fun resolve(
        mode: PowerManager.PowerMode,
        directPeerCount: Int,
        connectionCount: Int,
        maxConnections: Int
    ): Decision = when {
        directPeerCount < ISOLATED_BELOW_DIRECT_PEERS -> Decision(ANY_AUDIBLE_DBM, Reason.ISOLATED)
        maxConnections - connectionCount <= NEAR_CAPACITY_FREE_SLOTS ->
            Decision(strict(mode), Reason.NEAR_CAPACITY)
        else -> Decision(relaxed(mode), Reason.RELAXED)
    }

    private fun strict(mode: PowerManager.PowerMode): Int = when (mode) {
        PowerManager.PowerMode.PERFORMANCE -> STRICT_PERFORMANCE_DBM
        PowerManager.PowerMode.BALANCED -> STRICT_BALANCED_DBM
        PowerManager.PowerMode.POWER_SAVER -> STRICT_POWER_SAVER_DBM
        PowerManager.PowerMode.ULTRA_LOW_POWER -> STRICT_ULTRA_LOW_POWER_DBM
    }

    private fun relaxed(mode: PowerManager.PowerMode): Int = when (mode) {
        PowerManager.PowerMode.PERFORMANCE -> RELAXED_PERFORMANCE_DBM
        PowerManager.PowerMode.BALANCED -> RELAXED_BALANCED_DBM
        PowerManager.PowerMode.POWER_SAVER -> RELAXED_POWER_SAVER_DBM
        PowerManager.PowerMode.ULTRA_LOW_POWER -> RELAXED_ULTRA_LOW_POWER_DBM
    }
}
