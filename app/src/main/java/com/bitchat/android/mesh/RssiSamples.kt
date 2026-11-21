package com.bitchat.android.mesh

import java.util.concurrent.ConcurrentHashMap

/**
 * The latest advertisement RSSI heard per device address and per peer (P1-5, ADR-0013).
 *
 * A connected peer keeps advertising, so its scan RSSI stays fresh, while the RSSI stored on a link
 * is only the one from connect time. Judging "the weakest link" needs the fresh value. Samples are
 * keyed by peer as well as by address: Android reports a peer's inbound (server-side) link under a
 * different address than the one it advertises with, and the peerID in the advertisement's service
 * data is what ties the two together.
 */
internal class RssiSamples(private val clock: () -> Long = System::currentTimeMillis) {

    data class Sample(val rssi: Int, val atMs: Long)

    private val byAddress = ConcurrentHashMap<String, Sample>()
    private val byPeer = ConcurrentHashMap<String, Sample>()

    fun record(deviceAddress: String, peerID: String?, rssi: Int) {
        val sample = Sample(rssi, clock())
        byAddress[deviceAddress] = sample
        if (peerID != null) byPeer[peerID] = sample
        if (byAddress.size > PRUNE_ABOVE_ADDRESSES) prune(sample.atMs)
    }

    fun byAddress(deviceAddress: String): Sample? = byAddress[deviceAddress]

    fun byPeer(peerID: String): Sample? = byPeer[peerID]

    fun addressSnapshot(): Map<String, Int> = byAddress.mapValues { it.value.rssi }

    fun clear() {
        byAddress.clear()
        byPeer.clear()
    }

    private fun prune(now: Long) {
        byAddress.entries.removeIf { now - it.value.atMs > PRUNE_OLDER_THAN_MS }
        byPeer.entries.removeIf { now - it.value.atMs > PRUNE_OLDER_THAN_MS }
    }

    companion object {
        /**
         * Advertising addresses rotate (typically every 15 minutes), so samples for addresses that
         * are gone pile up. Past this many, samples older than [PRUNE_OLDER_THAN_MS] are dropped.
         */
        const val PRUNE_ABOVE_ADDRESSES = 256
        const val PRUNE_OLDER_THAN_MS = 10 * 60_000L

        /** The most recent of [samples]; on a tie, the first one. */
        fun freshest(vararg samples: Sample?): Sample? =
            samples.filterNotNull().maxByOrNull { it.atMs }
    }
}
