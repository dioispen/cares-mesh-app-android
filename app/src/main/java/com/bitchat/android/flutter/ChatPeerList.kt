package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.ui.splitSuffix
import com.bitchat.android.ui.truncateNickname

/**
 * The native mesh peer list and online count, rebuilt as pure functions for the Flutter chat (#53).
 *
 * Upstream composes its rows inside Composables that cannot be called from the bridge, so the
 * rules are reproduced here and fixed by `ChatPeerListTest`; Dart only renders the result and
 * derives no order, threshold or fallback of its own. Sources mirrored, all in
 * `app/src/main/java/com/bitchat/android/ui/`:
 *
 * - online count: `ChatHeader.kt` `MainHeader` → `PeerCounter` (connected peers minus ourselves).
 * - rows: `MeshPeerListSheet.kt` `PeopleSection` (order, display name, `#abcd` suffix) and
 *   `PeerItem` (name truncation, direct / routed / Wi-Fi Aware).
 * - signal bars: `MeshPeerListSheet.kt` `convertRSSIToSignalStrength` and the bar bands in its doc.
 * - unread badge (#56): the badge of the peer's online conversation (see [ChatUnread]).
 * - order: `PeopleSection` `sortedPeers` — peers with unread private messages first (#56), then the
 *   most recent private message (#55), then alphabetical.
 *
 * Deliberately not (yet) mirrored:
 * - `PeopleSection` sorts favourites after the most recent private chat. That key arrives with the
 *   field that makes it visible (#58 favourites); add it to [order] then, in that place.
 * - Offline favourites appended after the connected peers (#58); they must also be counted in the
 *   `#abcd` suffix de-duplication, as upstream counts them.
 * - Connected peers upstream moves into its "conversations" section; the Flutter chat has no such
 *   section yet, so every connected peer is listed. That is why a row's unread badge and "unread
 *   first" key come from the peer's conversation (`ChatViewModel.conversations`, as upstream's
 *   conversation rows show and sort them: `ConversationRow` → `UnreadBadge`) rather than from
 *   `PeopleSection`'s own lookups: the peers `PeopleSection` still shows are the ones without a
 *   conversation, so its unread keys (its sort looks the unread set up by mesh peer ID, which
 *   upstream replaces with a `contact_…` ID once it knows the peer's Noise key) rarely apply.
 * - Upstream's `peerID == nickname` → "You" branch compares a peer ID with our nickname and never
 *   meant to match; we leave ourselves out by peer ID instead, exactly as the online count does.
 */
object ChatPeerList {

    /** The upstream state the list is built from — `ChatViewModel` flows, read at one moment. */
    data class Inputs(
        val myPeerID: String,
        /** `ChatViewModel.connectedPeers`. */
        val connectedPeers: List<String>,
        /** `ChatViewModel.peerNicknames`: announced nicknames by peer ID. */
        val peerNicknames: Map<String, String>,
        /** `ChatViewModel.peerRSSI`: dBm of our own radio link, so only for direct peers. */
        val peerRSSI: Map<String, Int>,
        /** `ChatViewModel.peerDirect`, refreshed once a second. */
        val peerDirect: Map<String, Boolean>,
        /** Keys of `WifiAwareController.connectedPeers`. */
        val wifiAwarePeerIDs: Set<String>,
        /** `ChatViewModel.privateChats`, for the recency order and the display-name fallback. */
        val privateChats: Map<String, List<BitchatMessage>>,
        /** Upstream's conversations with unread messages ([ChatUnread.conversations]). */
        val unreadConversations: List<ChatUnread.Conversation> = emptyList()
    )

    /**
     * How we reach a peer, in upstream's precedence (`meshConnectionDescription`,
     * `conversationTransportIcon`): Wi-Fi Aware, then a direct Bluetooth link, else routed.
     */
    enum class Connection(val wire: String) {
        WIFI_AWARE("wifiAware"),
        BLUETOOTH("bluetooth"),
        ROUTED("routed")
    }

    /** One row as the native list shows it. */
    data class Row(
        val peerID: String,
        /** The raw announced nickname; null until the peer's announce is known. */
        val nickname: String?,
        /** The name the row shows: fallbacks applied, `#abcd` split off, truncated. */
        val displayName: String,
        /** `#abcd` when another listed peer shares [displayName]'s base name, otherwise "". */
        val displaySuffix: String,
        /** dBm; null when upstream has none (routed peers have no radio link to us). */
        val rssi: Int?,
        /** 0–3; null exactly when [rssi] is. */
        val signalBars: Int?,
        val connection: Connection,
        /** Unread private messages from this peer ([ChatUnread.countFor]); 0 when none. */
        val unreadCount: Int = 0
    )

    /** `PeerCounter`'s mesh count: `connectedPeers.filter { it != myPeerID }.size`. */
    fun onlineCount(inputs: Inputs): Int = inputs.connectedPeers.count { it != inputs.myPeerID }

    /**
     * The rows, in upstream order. [isDirectFallback] answers for peers `peerDirect` does not
     * cover yet (upstream asks `ChatViewModel.getMeshPeerInfo(id)?.isDirectConnection`).
     */
    fun rows(inputs: Inputs, isDirectFallback: (String) -> Boolean): List<Row> {
        val others = inputs.connectedPeers.filter { it != inputs.myPeerID }
        val unread = others.associateWith { ChatUnread.countFor(it, inputs.unreadConversations) }
        val peers = others.sortedWith(order(inputs, unread))
        val names = peers.map { displayNameOf(it, inputs) }
        // PeopleSection counts base names across every row it shows before deciding on suffixes.
        val baseNameCounts = names.groupingBy { splitSuffix(it).first }.eachCount()

        return peers.zip(names) { peerID, name ->
            val (baseName, suffix) = splitSuffix(name)
            val rssi = inputs.peerRSSI[peerID]
            Row(
                peerID = peerID,
                nickname = inputs.peerNicknames[peerID],
                displayName = truncateNickname(baseName),
                displaySuffix = if ((baseNameCounts[baseName] ?: 0) > 1) suffix else "",
                rssi = rssi,
                signalBars = signalBars(rssi),
                connection = connection(
                    isWifiAware = peerID in inputs.wifiAwarePeerIDs,
                    isDirect = inputs.peerDirect[peerID] ?: isDirectFallback(peerID)
                ),
                unreadCount = unread.getValue(peerID)
            )
        }
    }

    /**
     * Upstream's percentage (`convertRSSIToSignalStrength`: ≥ -40 → 100, ≥ -55 → 85, ≥ -70 → 70,
     * ≥ -85 → 50, ≥ -100 → 25, else 0) read through the bands its doc gives (99–100 → 3 bars,
     * 66–98 → 2, 33–65 → 1, 0–32 → 0). Upstream never draws it; this is the only RSSI scale it has.
     */
    fun signalBars(rssi: Int?): Int? = when {
        rssi == null -> null
        rssi >= -40 -> 3
        rssi >= -70 -> 2
        rssi >= -85 -> 1
        else -> 0
    }

    /**
     * PeopleSection's keys: unread private messages first ([unread], see the class doc for where
     * they come from; having any is the key, not how many) — then the newest private message
     * timestamp — upstream looks the peer up in `privateChats` by its mesh peer ID, so a
     * conversation already re-keyed to a `contact_…` ID does not count, in the native list either —
     * then nickname, else peer ID, lowercased. Stable for ties.
     */
    private fun order(inputs: Inputs, unread: Map<String, Int>): Comparator<String> =
        compareByDescending<String> { peerID -> (unread[peerID] ?: 0) > 0 }
            .thenByDescending { peerID ->
                inputs.privateChats[peerID]?.maxByOrNull { it.timestamp }?.timestamp?.time ?: 0L
            }
            .thenBy { (inputs.peerNicknames[it] ?: it).lowercase() }

    /** PeopleSection: nickname, else the last private message's sender, else the ID's prefix. */
    private fun displayNameOf(peerID: String, inputs: Inputs): String =
        inputs.peerNicknames[peerID]
            ?: inputs.privateChats[peerID]?.lastOrNull()?.sender
            ?: peerID.take(12)

    private fun connection(isWifiAware: Boolean, isDirect: Boolean): Connection = when {
        isWifiAware -> Connection.WIFI_AWARE
        isDirect -> Connection.BLUETOOTH
        else -> Connection.ROUTED
    }
}
