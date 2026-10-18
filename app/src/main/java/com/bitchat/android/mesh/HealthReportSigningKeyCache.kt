package com.bitchat.android.mesh

import com.bitchat.android.util.AppConstants

/**
 * Signing keys learned from verified ANNOUNCEs, kept apart from the live peer list so a Health
 * Report relayed by anti-entropy sync still verifies after its Reporter has left (#95).
 *
 * Holds public keys only, which every ANNOUNCE broadcasts in clear. Memory only, on purpose: kept
 * across restarts it would become a long-term record of who was nearby when. Each entry expires
 * [retentionMs] after its key was last learned, the same span a relay keeps a Health Report for.
 *
 * Only for verifying HEALTH_REPORT. It must never feed the peer list, private messages, Noise
 * handshakes or LEAVE.
 */
internal class HealthReportSigningKeyCache(
    private val retentionMs: Long = AppConstants.Sync.HEALTH_REPORT_RETENTION_MS,
    private val maxEntries: Int = AppConstants.Sync.MAX_HEALTH_REPORT_SIGNING_KEYS
) {
    private class Entry(
        val noisePublicKey: ByteArray,
        val signingPublicKey: ByteArray,
        val learnedAtMs: Long
    )

    // Insertion order is learn order: re-learning a key moves it to the end, so the first entry
    // is always the one learned longest ago.
    private val entries = LinkedHashMap<String, Entry>()

    /**
     * Records the keys from a verified ANNOUNCE of [peerID]. A key different from the one already
     * cached is a replacement and, like a live peer's key, is refused unless [authenticated] (the
     * signing key matches authenticated peer state). Returns whether the key is now cached.
     */
    @Synchronized
    fun remember(
        peerID: String,
        noisePublicKey: ByteArray,
        signingPublicKey: ByteArray,
        nowMs: Long,
        authenticated: Boolean = false
    ): Boolean {
        pruneExpired(nowMs)
        val existing = entries[peerID]
        val conflicts = existing != null && (
            !existing.noisePublicKey.contentEquals(noisePublicKey) ||
                !existing.signingPublicKey.contentEquals(signingPublicKey)
            )
        if (conflicts && !authenticated) return false

        entries.remove(peerID)
        entries[peerID] = Entry(noisePublicKey.copyOf(), signingPublicKey.copyOf(), nowMs)
        while (entries.size > maxEntries) {
            val oldest = entries.keys.iterator()
            oldest.next()
            oldest.remove()
        }
        return true
    }

    @Synchronized
    fun signingKeyFor(peerID: String, nowMs: Long): ByteArray? {
        val entry = entries[peerID] ?: return null
        if (isExpired(entry, nowMs)) {
            entries.remove(peerID)
            return null
        }
        return entry.signingPublicKey.copyOf()
    }

    @Synchronized
    fun pruneExpired(nowMs: Long) {
        entries.values.removeAll { isExpired(it, nowMs) }
    }

    @Synchronized
    fun clear() {
        entries.clear()
    }

    private fun isExpired(entry: Entry, nowMs: Long): Boolean = nowMs - entry.learnedAtMs > retentionMs
}
