package com.bitchat.android.sync

import android.util.Log
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.util.AppConstants
import com.bitchat.android.util.toHexString
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

/**
 * The one durable slot [OwnHealthReportKeeper] writes the encoded packet to. Calls block on disk
 * I/O; the keeper makes them off the main thread, except [clear] on the panic path.
 */
interface OwnHealthReportStore {
    fun read(): ByteArray?
    fun write(encoded: ByteArray)
    /** Returns once the slot is erased on disk. */
    fun clear()
}

/**
 * Which packets are the Reporter's own Health Report, and whether a kept one may still be served
 * by sync. Expiry is GossipSyncManager's: [AppConstants.Sync.HEALTH_REPORT_RETENTION_MS] from the
 * packet's own timestamp.
 */
object OwnHealthReportPolicy {

    /** A signed, broadcast Health Report sent under [myPeerID]. */
    fun isOwnSignedHealthReport(packet: BitchatPacket, myPeerID: String): Boolean {
        val isBroadcast = packet.recipientID == null ||
            packet.recipientID.contentEquals(SpecialRecipients.BROADCAST)
        return packet.type == MessageType.HEALTH_REPORT.value &&
            isBroadcast &&
            packet.signature != null &&
            packet.senderID.toHexString().equals(myPeerID, ignoreCase = true)
    }

    /** Not older than the retention period, by the packet's own timestamp. */
    fun isUnexpired(packet: BitchatPacket, nowMs: Long): Boolean =
        nowMs - packet.timestamp.toLong() <= AppConstants.Sync.HEALTH_REPORT_RETENTION_MS

    /** Ours, and GossipSyncManager would still take it. */
    fun isRestorable(packet: BitchatPacket, myPeerID: String, nowMs: Long): Boolean =
        isOwnSignedHealthReport(packet, myPeerID) && isUnexpired(packet, nowMs)

    /**
     * Whether [candidate], just broadcast, takes the place of [kept]. The newest timestamp wins, as
     * in GossipSyncManager, so a send that finishes late never replaces a newer one.
     */
    fun shouldReplace(kept: BitchatPacket?, candidate: BitchatPacket, myPeerID: String, nowMs: Long): Boolean =
        isRestorable(candidate, myPeerID, nowMs) &&
            (kept == null || !isRestorable(kept, myPeerID, nowMs) || candidate.timestamp > kept.timestamp)
}

/**
 * Keeps the Reporter's own latest signed Health Report across app restarts (four-phone trial
 * 2026-11-18, §7.1 / P0-3).
 *
 * Sync can only repair a report somebody holds. A report sent while every link was already dead
 * reached nobody, and once the app restarted its own sync store was empty too, so no neighbour
 * could ever get it. The mesh service passes each packet it signs and broadcasts to [keep], and on
 * start puts [latest] back into GossipSyncManager: neighbours that connect later receive it by sync.
 *
 * What is kept is the signed packet itself, encoded as on the wire. Restored, it has the same
 * packet ID, signature and timestamp, so it still expires 2 h after it was first sent; it is never
 * re-signed or re-timestamped here. Restoring runs in the mesh service, not in Flutter, so it also
 * works when only MeshForegroundService is running.
 *
 * The SOS re-sender (ADR-0012) sends the kept report again under a new timestamp while it stands;
 * that send comes back through [keep] like any other, so the slot always holds the last one sent.
 */
class OwnHealthReportKeeper(
    private val myPeerID: String,
    private val store: OwnHealthReportStore,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /**
     * A kept report this is true for stays past its sync expiry, for [latestOwn]: a standing SOS
     * is re-sent from it however long the phone was off (ADR-0012). Any other is erased then.
     */
    private val keepPastExpiry: (BitchatPacket) -> Boolean = { false }
) {
    private val lock = Any()

    // Bumped by clear(): a report sent before a panic wipe must not be written after it
    @Volatile
    private var generation = 0L

    /** [signed] was just signed and broadcast by this device; kept if it is our newest Health Report. */
    suspend fun keep(signed: BitchatPacket) {
        if (!OwnHealthReportPolicy.isOwnSignedHealthReport(signed, myPeerID)) return
        val sentInGeneration = generation
        withContext(ioDispatcher) { keepNow(signed, sentInGeneration) }
    }

    /**
     * Our latest Health Report while sync may still serve it, else null. A kept report that has
     * expired (unless [keepPastExpiry]), was sent under another identity (panic wipe, reinstall)
     * or cannot be read is erased: it records where the Reporter was, so it is kept no longer than
     * it is of use.
     */
    suspend fun latest(): BitchatPacket? = withContext(ioDispatcher) {
        latestNow()?.takeIf { OwnHealthReportPolicy.isUnexpired(it, nowMs()) }
    }

    /** Like [latest], but also a report past its sync expiry that [keepPastExpiry] holds on to. */
    suspend fun latestOwn(): BitchatPacket? = withContext(ioDispatcher) { latestNow() }

    /**
     * Erases the kept report; a [keep] still in flight writes nothing. Blocks on the disk write:
     * for panic paths, which must finish erasing before they go on.
     */
    fun clear() {
        synchronized(lock) {
            generation++
            erase()
        }
        changeCount.update { it + 1 }
    }

    private fun keepNow(signed: BitchatPacket, sentInGeneration: Long) {
        synchronized(lock) {
            if (generation != sentInGeneration) return
            val kept = readSlot()?.let { BitchatPacket.fromBinaryData(it) }
            if (!OwnHealthReportPolicy.shouldReplace(kept, signed, myPeerID, nowMs())) return
            val encoded = signed.toBinaryData(padding = false) ?: return
            try {
                store.write(encoded)
            } catch (e: Exception) {
                Log.w(TAG, "Could not keep own health report: ${e.message}")
                return
            }
        }
        changeCount.update { it + 1 }
    }

    private fun latestNow(): BitchatPacket? {
        synchronized(lock) {
            val encoded = readSlot() ?: return null
            val kept = BitchatPacket.fromBinaryData(encoded)
            if (kept != null &&
                OwnHealthReportPolicy.isOwnSignedHealthReport(kept, myPeerID) &&
                (OwnHealthReportPolicy.isUnexpired(kept, nowMs()) || keepPastExpiry(kept))
            ) {
                return kept
            }
            // Not announced on changes: nobody needs to act on a record that was of no use
            erase()
            return null
        }
    }

    private fun readSlot(): ByteArray? = try {
        store.read()
    } catch (e: Exception) {
        Log.w(TAG, "Could not read own health report: ${e.message}")
        null
    }

    private fun erase() {
        try {
            store.clear()
        } catch (e: Exception) {
            Log.w(TAG, "Could not erase own health report: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "OwnHealthReportKeeper"

        private val changeCount = MutableStateFlow(0L)

        /**
         * Moves on whenever a keeper has written a report or been cleared. Process-wide, not per
         * keeper: the mesh service that owns one is replaced (panic, restart) without telling
         * those who read it. The SOS re-sender (ADR-0012) reads the kept report again on it.
         */
        val changes: StateFlow<Long> = changeCount.asStateFlow()
    }
}
