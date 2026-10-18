package com.bitchat.android.mesh

import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.util.AppConstants

/**
 * Signing keys learned from verified ANNOUNCEs, kept apart from the live peer list so a Health
 * Report relayed by anti-entropy sync still verifies after its Reporter has left (#95).
 *
 * Also keeps the signed ANNOUNCE itself: a relay that learned the key this way has no other copy
 * to pass on with the report, and the next hop needs one to verify it without trusting the relay.
 *
 * Holds what every ANNOUNCE broadcasts in clear (public keys, nickname). Memory only, on purpose: kept
 * across restarts it would become a long-term record of who was nearby when. Each entry expires
 * [retentionMs] after its key was last learned, the same span a relay keeps a Health Report for.
 *
 * Only for verifying HEALTH_REPORT and passing on the ANNOUNCE a report needs. It must never feed
 * the peer list, private messages, Noise handshakes or LEAVE.
 */
internal class HealthReportSigningKeyCache(
    private val retentionMs: Long = AppConstants.Sync.HEALTH_REPORT_RETENTION_MS,
    private val maxEntries: Int = AppConstants.Sync.MAX_HEALTH_REPORT_SIGNING_KEYS
) {
    private class Entry(
        val noisePublicKey: ByteArray,
        val signingPublicKey: ByteArray,
        /** The signed ANNOUNCE the keys came from; a relay passes it on with the report. */
        val announcement: BitchatPacket,
        val learnedAtMs: Long
    )

    // Insertion order is learn order: re-learning a key moves it to the end, so the first entry
    // is always the one learned longest ago.
    private val entries = LinkedHashMap<String, Entry>()

    /**
     * Records the keys from [announcement], a verified ANNOUNCE of [peerID]. A key different from
     * the one already cached is a replacement and, like a live peer's key, is refused unless
     * [authenticated] (the signing key matches authenticated peer state). Of two announcements
     * carrying the same keys the newer is kept. Returns whether the key is now cached.
     */
    @Synchronized
    fun remember(
        peerID: String,
        noisePublicKey: ByteArray,
        signingPublicKey: ByteArray,
        announcement: BitchatPacket,
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

        val kept = existing?.announcement
            ?.takeIf { !conflicts && it.timestamp > announcement.timestamp }
            ?: announcement
        entries.remove(peerID)
        entries[peerID] = Entry(noisePublicKey.copyOf(), signingPublicKey.copyOf(), kept, nowMs)
        while (entries.size > maxEntries) {
            val oldest = entries.keys.iterator()
            oldest.next()
            oldest.remove()
        }
        return true
    }

    @Synchronized
    fun signingKeyFor(peerID: String, nowMs: Long): ByteArray? = liveEntry(peerID, nowMs)?.signingPublicKey?.copyOf()

    /** The signed ANNOUNCE the cached key of [peerID] came from, to pass on with their Health Report. */
    @Synchronized
    fun announcementFor(peerID: String, nowMs: Long): BitchatPacket? = liveEntry(peerID, nowMs)?.announcement

    private fun liveEntry(peerID: String, nowMs: Long): Entry? {
        val entry = entries[peerID] ?: return null
        if (isExpired(entry, nowMs)) {
            entries.remove(peerID)
            return null
        }
        return entry
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
