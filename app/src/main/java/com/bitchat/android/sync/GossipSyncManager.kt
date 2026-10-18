package com.bitchat.android.sync

import android.util.Log
import com.bitchat.android.experiment.ExperimentRecorder
import com.bitchat.android.mesh.BluetoothPacketBroadcaster
import com.bitchat.android.model.RequestSyncPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap

/**
 * Gossip-based synchronization manager using on-demand GCS filters.
 * Tracks seen public packets (ANNOUNCE, broadcast MESSAGE, broadcast HEALTH_REPORT) and
 * periodically requests sync from neighbors. Responds to REQUEST_SYNC by sending missing packets.
 */
class GossipSyncManager(
    private val myPeerID: String,
    private val scope: CoroutineScope,
    private val configProvider: ConfigProvider,
    private val nowMs: () -> Long = System::currentTimeMillis,
    /** Field-experiment SYNC hook (#70, #91); only the BLE mesh passes a recording one. */
    private val experimentRecorder: ExperimentRecorder = ExperimentRecorder.NoOp,
    /**
     * The announcement a sender's Health Report signing key was learned from, by sender peerID
     * (`SecurityManager.healthReportAnnouncementFor`). Used for a held report whose sender has no
     * stored announcement because we only ever heard an old one (#95).
     */
    private val cachedAnnouncementFor: (senderPeerID: String) -> BitchatPacket? = { null }
) {
    interface Delegate {
        fun sendPacket(packet: BitchatPacket)
        fun sendPacketToPeer(peerID: String, packet: BitchatPacket)
        fun signPacketForBroadcast(packet: BitchatPacket): BitchatPacket
    }

    interface ConfigProvider {
        fun seenCapacity(): Int // max packets we sync per request (cap across types)
        fun gcsMaxBytes(): Int
        fun gcsTargetFpr(): Double // percent -> 0.0..1.0
    }

    companion object {
        private const val TAG = "GossipSyncManager"
    }

    var delegate: Delegate? = null

    // Defaults (configurable constants)
    private val defaultMaxBytes = SyncDefaults.DEFAULT_FILTER_BYTES
    private val defaultFpr = SyncDefaults.DEFAULT_FPR_PERCENT

    // Stored packets for sync:
    // - broadcast messages: keep up to seenCapacity() most recent, keyed by packetId
    private val messages = LinkedHashMap<String, BitchatPacket>()
    // - announcements: only keep latest per sender peerID. Dropped once older than
    //   STALE_PEER_TIMEOUT_MS or when the peer is removed, except while we still hold that sender's
    //   Health Report: a receiver that never met the sender needs it first to learn the signing
    //   key the report is verified with (#95). handleRequestSync sends announcements first.
    private val latestAnnouncementByPeer = ConcurrentHashMap<String, Pair<String, BitchatPacket>>()
    // - health reports: only keep latest per sender peerID. Expire by their own timestamp
    //   (HEALTH_REPORT_RETENTION_MS), not with the sender's announcement: a Reporter whose phone
    //   died or who walked out of range is exactly when the report still needs relaying.
    private val latestHealthReportBySender = ConcurrentHashMap<String, Pair<String, BitchatPacket>>()

    private var periodicJob: Job? = null
    private var cleanupJob: Job? = null
    fun start() {
        periodicJob?.cancel()
        periodicJob = scope.launch(Dispatchers.IO) {
            while (isActive) {
                try {
                    delay(30_000)
                    sendRequestSync()
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { Log.e(TAG, "Periodic sync error: ${e.message}") }
            }
        }

        // Start periodic cleanup of stale announcements and messages
        cleanupJob?.cancel()
        cleanupJob = scope.launch(Dispatchers.IO) {
            while (isActive) {
                try {
                    delay(com.bitchat.android.util.AppConstants.Sync.CLEANUP_INTERVAL_MS)
                    pruneStaleAnnouncements()
                    pruneExpiredHealthReports()
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { Log.e(TAG, "Periodic cleanup error: ${e.message}") }
            }
        }
    }

    fun stop() {
        periodicJob?.cancel(); periodicJob = null
        cleanupJob?.cancel(); cleanupJob = null
    }

    @Synchronized
    fun clear() {
        synchronized(messages) {
            messages.clear()
        }
        latestAnnouncementByPeer.clear()
        latestHealthReportBySender.clear()
        Log.d(TAG, "Cleared all gossip sync messages, announcements and health reports")
    }

    fun scheduleInitialSync(delayMs: Long = 5_000L) {
        scope.launch(Dispatchers.IO) {
            delay(delayMs)
            sendRequestSync()
        }
    }

    fun scheduleInitialSyncToPeer(peerID: String, delayMs: Long = 5_000L) {
        scope.launch(Dispatchers.IO) {
            delay(delayMs)
            sendRequestSyncToPeer(peerID)
        }
    }

    fun onPublicPacketSeen(packet: BitchatPacket) {
        // Only ANNOUNCE, broadcast MESSAGE or broadcast HEALTH_REPORT
        val mt = MessageType.fromValue(packet.type)
        val isBroadcast = (packet.recipientID == null || packet.recipientID.contentEquals(SpecialRecipients.BROADCAST))
        val isBroadcastMessage = (mt == MessageType.MESSAGE && isBroadcast)
        val isAnnouncement = (mt == MessageType.ANNOUNCE)
        val isBroadcastHealthReport = (mt == MessageType.HEALTH_REPORT && isBroadcast)
        if (!isBroadcastMessage && !isAnnouncement && !isBroadcastHealthReport) return

        val idBytes = PacketIdUtil.computeIdBytes(packet)
        val id = idBytes.joinToString("") { b -> "%02x".format(b) }

        if (isBroadcastMessage) {
            synchronized(messages) {
                messages[id] = packet
                // Enforce capacity (remove oldest when exceeded)
                val cap = configProvider.seenCapacity().coerceAtLeast(1)
                while (messages.size > cap) {
                    val it = messages.entries.iterator()
                    if (it.hasNext()) { it.next(); it.remove() } else break
                }
            }
        } else if (isAnnouncement) {
            // Ignore stale announcements older than STALE_PEER_TIMEOUT
            val now = nowMs()
            if (isStaleAnnouncement(packet, now)) {
                Log.d(TAG, "Ignoring stale ANNOUNCE (age=${now - packet.timestamp.toLong()}ms > ${AppConstants.Mesh.STALE_PEER_TIMEOUT_MS}ms)")
                return
            }
            // senderID is fixed-size 8 bytes; map to hex string for key
            val sender = packet.senderID.joinToString("") { b -> "%02x".format(b) }
            latestAnnouncementByPeer[sender] = id to packet
            // Enforce capacity (remove oldest when exceeded)
            val cap = configProvider.seenCapacity().coerceAtLeast(1)
            while (latestAnnouncementByPeer.size > cap) {
                val it = latestAnnouncementByPeer.entries.iterator()
                if (it.hasNext()) { it.next(); it.remove() } else break
            }
        } else if (isBroadcastHealthReport) {
            val age = nowMs() - packet.timestamp.toLong()
            if (age > AppConstants.Sync.HEALTH_REPORT_RETENTION_MS) {
                Log.d(TAG, "Ignoring expired HEALTH_REPORT (age=${age}ms)")
                return
            }
            val sender = packet.senderID.joinToString("") { b -> "%02x".format(b) }
            // A relayed or synced copy can arrive after a newer one: keep the newest only
            latestHealthReportBySender.compute(sender) { _, existing ->
                if (existing == null || packet.timestamp > existing.second.timestamp) id to packet else existing
            }
            // Enforce capacity (drop the oldest report when exceeded)
            val cap = configProvider.seenCapacity().coerceAtLeast(1)
            while (latestHealthReportBySender.size > cap) {
                val oldest = latestHealthReportBySender.entries.minByOrNull { it.value.second.timestamp } ?: break
                latestHealthReportBySender.remove(oldest.key, oldest.value)
            }
        }
    }

    private fun sendRequestSync() {
        val payload = buildGcsPayload()

        val packet = BitchatPacket(
            type = MessageType.REQUEST_SYNC.value,
            senderID = hexStringToByteArray(myPeerID),
            timestamp = System.currentTimeMillis().toULong(),
            payload = payload,
            ttl = com.bitchat.android.util.AppConstants.SYNC_TTL_HOPS // neighbors only
        )
        // Sign and broadcast
        val signed = delegate?.signPacketForBroadcast(packet) ?: packet
        delegate?.sendPacket(signed)
    }

    private fun sendRequestSyncToPeer(peerID: String) {
        val payload = buildGcsPayload()

        val packet = BitchatPacket(
            type = MessageType.REQUEST_SYNC.value,
            senderID = hexStringToByteArray(myPeerID),
            recipientID = hexStringToByteArray(peerID),
            timestamp = System.currentTimeMillis().toULong(),
            payload = payload,
            ttl = com.bitchat.android.util.AppConstants.SYNC_TTL_HOPS // neighbor only
        )
        Log.d(TAG, "Sending sync request to $peerID (${payload.size} bytes)")
        // Sign and send directly to peer
        val signed = delegate?.signPacketForBroadcast(packet) ?: packet
        delegate?.sendPacketToPeer(peerID, signed)
    }

    fun handleRequestSync(fromPeerID: String, request: RequestSyncPacket) {
        // Decode GCS into sorted set for membership checks
        val sorted = GCSFilter.decodeToSortedSet(request.p, request.m, request.data)
        fun mightContain(id: ByteArray): Boolean {
            val v = GCSFilter.h64(id) % request.m
            val nonZeroV = if (v == 0L) 1L else v
            return GCSFilter.contains(sorted, nonZeroV)
        }

        // 1) Announcements: send latest per peerID if remote doesn't have them
        for ((_, pair) in latestAnnouncementByPeer.entries) {
            val (id, pkt) = pair
            val idBytes = hexToBytes(id)
            if (!mightContain(idBytes)) {
                // Send original packet unchanged to requester only (keep local TTL)
                val toSend = pkt.copy(ttl = com.bitchat.android.util.AppConstants.SYNC_TTL_HOPS)
                sendSyncReply(fromPeerID, toSend)
                Log.d(TAG, "Sent sync announce: Type ${toSend.type} from ${toSend.senderID.toHexString()} to $fromPeerID packet id ${idBytes.toHexString()}")
            }
        }

        // 2) Health reports: send latest per sender if remote doesn't have them
        for ((sender, pair) in latestHealthReportBySender.entries) {
            val (id, pkt) = pair
            val idBytes = hexToBytes(id)
            if (!mightContain(idBytes)) {
                // Without a stored announcement for the sender, the one our key came from goes
                // first, or a requester that never met the sender cannot verify the report
                cachedAnnouncementOfHeldReport(sender)
                    ?.takeIf { !mightContain(PacketIdUtil.computeIdBytes(it)) }
                    ?.let { announcement ->
                        sendSyncReply(fromPeerID, announcement.copy(ttl = AppConstants.SYNC_TTL_HOPS))
                        Log.d(TAG, "Sent cached announce of $sender ahead of their health report to $fromPeerID")
                    }
                // Original signed packet, neighbor only; the receiver verifies and dedups as usual
                val toSend = pkt.copy(ttl = AppConstants.SYNC_TTL_HOPS)
                sendSyncReply(fromPeerID, toSend)
                Log.d(TAG, "Sent sync health report from ${toSend.senderID.toHexString()} to $fromPeerID packet id ${idBytes.toHexString()}")
            }
        }

        // 3) Broadcast messages: send all they lack
        val toSendMsgs = synchronized(messages) { messages.values.toList() }
        for (pkt in toSendMsgs) {
            val idBytes = PacketIdUtil.computeIdBytes(pkt)
            if (!mightContain(idBytes)) {
                val toSend = pkt.copy(ttl = com.bitchat.android.util.AppConstants.SYNC_TTL_HOPS)
                sendSyncReply(fromPeerID, toSend)
                Log.d(TAG, "Sent sync message: Type ${toSend.type} to $fromPeerID packet id ${idBytes.toHexString()}")
            }
        }
    }

    // A stored announcement always wins: it is sent and advertised in its own right (#95).
    // Only one older than the peer timeout is passed on: sent at TTL 0, the receiver then uses it
    // for the key alone and does not take the sender to be present. The signature covers every
    // field but TTL, so the announcement itself cannot carry such a mark.
    private fun cachedAnnouncementOfHeldReport(sender: String): BitchatPacket? {
        if (latestAnnouncementByPeer.containsKey(sender)) return null
        return cachedAnnouncementFor(sender)?.takeIf { isStaleAnnouncement(it, nowMs()) }
    }

    // Receivers cannot tell a synced copy from a flooded one (same signed packet, TTL may be 0
    // either way), so field experiments record each reply on the serving side instead (#91)
    private fun sendSyncReply(peerID: String, packet: BitchatPacket) {
        delegate?.sendPacketToPeer(peerID, packet)
        experimentRecorder.onSyncSent(packet, peerID)
    }

    private fun hexStringToByteArray(hexString: String): ByteArray {
        val result = ByteArray(8) { 0 }
        var tempID = hexString
        var index = 0
        while (tempID.length >= 2 && index < 8) {
            val hexByte = tempID.substring(0, 2)
            val byte = hexByte.toIntOrNull(16)?.toByte()
            if (byte != null) result[index] = byte
            tempID = tempID.substring(2)
            index++
        }
        return result
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = if (hex.length % 2 == 0) hex else "0$hex"
        val out = ByteArray(clean.length / 2)
        var i = 0
        while (i < clean.length) {
            out[i/2] = clean.substring(i, i+2).toInt(16).toByte()
            i += 2
        }
        return out
    }

    internal fun buildGcsPayload(): ByteArray {
        // Collect candidates: latest announcement and health report per peer + recent broadcast messages
        val list = ArrayList<BitchatPacket>()
        // announcements
        for ((_, pair) in latestAnnouncementByPeer) {
            list.add(pair.second)
        }
        // health reports, and the cached announcement of any sender we hold no announcement for
        // (otherwise the neighbor that sent it to us would resend it every round)
        for ((sender, pair) in latestHealthReportBySender) {
            list.add(pair.second)
            cachedAnnouncementOfHeldReport(sender)?.let(list::add)
        }
        // messages
        synchronized(messages) {
            list.addAll(messages.values)
        }
        // sort by timestamp desc, then take up to min(seenCapacity, fit capacity)
        list.sortByDescending { it.timestamp.toLong() }

        val maxBytes = try { configProvider.gcsMaxBytes() } catch (_: Exception) { defaultMaxBytes }
        val fpr = try { configProvider.gcsTargetFpr() } catch (_: Exception) { defaultFpr }
        val p = GCSFilter.deriveP(fpr)
        val nMax = GCSFilter.estimateMaxElementsForSize(maxBytes, p)
        val cap = configProvider.seenCapacity().coerceAtLeast(1)
        val takeN = minOf(nMax, cap, list.size)
        if (takeN <= 0) {
            val p0 = GCSFilter.deriveP(fpr)
            return RequestSyncPacket(p = p0, m = 1, data = ByteArray(0)).encode()
        }
        val ids = list.take(takeN).map { pkt -> PacketIdUtil.computeIdBytes(pkt) }
        val params = GCSFilter.buildFilter(ids, maxBytes, fpr)
        val mVal = if (params.m <= 0L) 1 else params.m
        return RequestSyncPacket(p = params.p, m = mVal, data = params.data).encode()
    }

    // Periodically remove stale announcements and all their messages. The announcement of a
    // sender whose Health Report we still hold stays (#95); their messages go regardless.
    internal fun pruneStaleAnnouncements() {
        val now = nowMs()
        val stale = latestAnnouncementByPeer.entries
            .filter { (_, pair) -> isStaleAnnouncement(pair.second, now) }
            .map { it.key to it.value }
        if (stale.isEmpty()) return

        var prunedAnnouncements = 0
        var totalPrunedMsgs = 0
        for ((peerID, pair) in stale) {
            totalPrunedMsgs += removeMessagesFromSender(peerID)
            // Conditional remove: a newer announcement may have replaced it meanwhile
            if (!latestHealthReportBySender.containsKey(peerID) &&
                latestAnnouncementByPeer.remove(peerID, pair)
            ) {
                prunedAnnouncements++
                restoreAnnouncementIfReportArrived(peerID, pair)
            }
        }

        if (prunedAnnouncements > 0 || totalPrunedMsgs > 0) {
            Log.d(TAG, "Pruned $prunedAnnouncements stale announcements and $totalPrunedMsgs messages")
        }
    }

    // Periodically remove health reports older than HEALTH_REPORT_RETENTION_MS
    internal fun pruneExpiredHealthReports() {
        val now = nowMs()
        var pruned = 0
        for ((sender, pair) in latestHealthReportBySender.entries) {
            val age = now - pair.second.timestamp.toLong()
            if (age > AppConstants.Sync.HEALTH_REPORT_RETENTION_MS &&
                latestHealthReportBySender.remove(sender, pair)
            ) {
                pruned++
                // The announcement was only kept for this report (#95)
                latestAnnouncementByPeer[sender]?.let { announcement ->
                    if (isStaleAnnouncement(announcement.second, now) &&
                        latestAnnouncementByPeer.remove(sender, announcement)
                    ) {
                        restoreAnnouncementIfReportArrived(sender, announcement)
                    }
                }
            }
        }
        if (pruned > 0) Log.d(TAG, "Pruned $pruned expired health reports")
    }

    // The checks above test for a held Health Report and then remove the announcement in two
    // steps; a report stored in between would be left without the announcement it needs (#95)
    private fun restoreAnnouncementIfReportArrived(sender: String, announcement: Pair<String, BitchatPacket>) {
        if (latestHealthReportBySender.containsKey(sender)) {
            latestAnnouncementByPeer.putIfAbsent(sender, announcement)
        }
    }

    private fun isStaleAnnouncement(packet: BitchatPacket, now: Long): Boolean =
        now - packet.timestamp.toLong() > AppConstants.Mesh.STALE_PEER_TIMEOUT_MS

    // Explicitly remove stored announcement for a given peer (hex ID), along with their messages.
    // Health reports are kept on purpose: they expire on their own (pruneExpiredHealthReports),
    // and so does the announcement while one of them is held (#95).
    fun removeAnnouncementForPeer(peerID: String) {
        val key = peerID.lowercase()
        if (!latestHealthReportBySender.containsKey(key)) {
            latestAnnouncementByPeer.remove(key)?.let { removed ->
                Log.d(TAG, "Removed stored announcement for peer $peerID")
                restoreAnnouncementIfReportArrived(key, removed)
            }
        }

        val prunedMsgs = removeMessagesFromSender(key)
        if (prunedMsgs > 0) {
            Log.d(TAG, "Pruned $prunedMsgs messages with senders without announcements")
        }
    }

    private fun removeMessagesFromSender(sender: String): Int = synchronized(messages) {
        val before = messages.size
        messages.values.removeAll { message ->
            message.senderID.joinToString("") { b -> "%02x".format(b) } == sender
        }
        before - messages.size
    }
}
