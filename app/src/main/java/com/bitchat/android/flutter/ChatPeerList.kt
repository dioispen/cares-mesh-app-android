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
 * - who is listed (#73): `MeshPeerListSheet`'s `visibleConnectedPeers` — a connected peer upstream
 *   knows by an ID one of the listed conversations is known by (`ContactDirectory
 *   .aliasesForConversation` against `conversationIdentityAliases`, ignoring case) is shown in the
 *   conversations section above instead ([ChatConversations]); `PeopleSection`'s header counts the
 *   rest ([peopleCount]). The online count still counts every connected peer.
 * - signal bars: `MeshPeerListSheet.kt` `convertRSSIToSignalStrength` and the bar bands in its doc.
 * - unread badge (#56): the badge of the peer's online conversation (see [ChatUnread]). Since #73
 *   a peer with a listed conversation is shown there, so a row listed here rarely has one; it is
 *   kept as the conversation's badge (`ConversationRow` → `UnreadBadge`) rather than
 *   `PeopleSection`'s lookups of the raw unread set, which would also count a blocked peer's
 *   hidden messages (#58: its conversation is not listed, so the peer is listed here).
 * - favourite star (#58): `PeopleSection` `peerFavoriteStates` / `peerTheyFavoritedUsStates`, by the
 *   peer's fingerprint (`ChatViewModel.peerFingerprints`), see [ChatFavorites.status].
 * - order: `PeopleSection` `sortedPeers` — peers with unread private messages first (#56), then the
 *   most recent private message (#55), then favourites (#58), then alphabetical.
 * - offline favourites (#58): `PeopleSection` `offlineFavoriteRows` — our favourites in upstream's
 *   store that no listed connected peer is (same Noise key, or same Nostr key) and that have no
 *   listed conversation (their Noise key is not among the conversations' aliases, #73: upstream
 *   lists those among its conversations), appended after the connected peers in the store's order,
 *   keyed by their Noise key (what upstream opens their private chat with), named by the record and
 *   counted in the `#abcd` de-duplication.
 *
 * Deliberately not mirrored:
 * - The offline favourite's "reachable over Nostr" globe (mutual favourite with a Nostr key): this
 *   app has Nostr disabled, so no favourite is reachable that way.
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
        val unreadConversations: List<ChatUnread.Conversation> = emptyList(),
        /** `ChatViewModel.favoritePeers`: fingerprints we favourited. */
        val favoritePeers: Set<String> = emptySet(),
        /** `ChatViewModel.peerFavoritedUs`: fingerprints that favourited us. */
        val peerFavoritedUs: Set<String> = emptySet(),
        /** `ChatViewModel.peerFingerprints`: connected peer ID → fingerprint. */
        val peerFingerprints: Map<String, String> = emptyMap(),
        /** Our favourites in upstream's store, in its order ([ChatRecords.ourFavorites]). */
        val ourFavorites: List<ChatFavorites.Favorite> = emptyList(),
        /** Connected peer ID → its Noise key (mesh peer info, else the cached key), any case. */
        val peerNoiseKeys: Map<String, String> = emptyMap(),
        /** Connected peer ID → the hex Nostr key upstream indexed for it, any case. */
        val peerNostrKeys: Map<String, String> = emptyMap(),
        /**
         * Every ID the conversations listed above the people are known by
         * ([ChatConversations.identityAliases]); empty when none is listed.
         */
        val conversationAliases: Set<String> = emptySet(),
        /**
         * Connected peer ID → the IDs upstream knows it by (`ContactDirectory.aliasesForConversation`,
         * [ChatRecords.conversationAliases]); a peer missing here is known by its own ID only. Only
         * needed while [conversationAliases] is not empty.
         */
        val peerAliases: Map<String, Set<String>> = emptyMap()
    )

    /**
     * How we reach a peer, in upstream's precedence (`meshConnectionDescription`,
     * `conversationTransportIcon`): Wi-Fi Aware, then a direct Bluetooth link, else routed — or not
     * at all right now: an offline favourite (`PeerItem`'s "offline favorite" badge).
     */
    enum class Connection(val wire: String) {
        WIFI_AWARE("wifiAware"),
        BLUETOOTH("bluetooth"),
        ROUTED("routed"),
        OFFLINE("offline")
    }

    /** One row as the native list shows it. */
    data class Row(
        /** A connected peer's mesh peer ID; an offline favourite's Noise key. */
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
        val unreadCount: Int = 0,
        /** We favourited them (see [ChatFavorites.status]); always true for an offline row. */
        val isFavorite: Boolean = false,
        /** They told us they favourited us. */
        val theyFavoritedUs: Boolean = false
    )

    /** `PeerCounter`'s mesh count: `connectedPeers.filter { it != myPeerID }.size`. */
    fun onlineCount(inputs: Inputs): Int = inputs.connectedPeers.count { it != inputs.myPeerID }

    /**
     * `PeopleSection`'s header count (`peopleCount`): the connected peers it lists — those without a
     * listed conversation ([listedPeers]) — minus ourselves.
     */
    fun peopleCount(inputs: Inputs): Int = listedPeers(inputs).count { it != inputs.myPeerID }

    /**
     * `visibleConnectedPeers`: the connected peers none of whose IDs a listed conversation is known
     * by (#73) — those are listed in the conversations section instead.
     */
    private fun listedPeers(inputs: Inputs): List<String> {
        if (inputs.conversationAliases.isEmpty()) return inputs.connectedPeers
        return inputs.connectedPeers.filterNot { peerID ->
            (inputs.peerAliases[peerID] ?: setOf(peerID)).any { it.lowercase() in inputs.conversationAliases }
        }
    }

    /**
     * The rows, in upstream order: the connected peers, then the offline favourites — without those
     * listed in the conversations section (#73).
     * [favoriteFallbacks] answer a connected peer's star while its fingerprint is unknown;
     * [isDirectFallback] answers for peers `peerDirect` does not cover yet (upstream asks
     * `ChatViewModel.getMeshPeerInfo(id)?.isDirectConnection`).
     */
    fun rows(
        inputs: Inputs,
        favoriteFallbacks: ChatFavorites.Fallbacks = ChatFavorites.Fallbacks.NONE,
        isDirectFallback: (String) -> Boolean
    ): List<Row> {
        val others = listedPeers(inputs).filter { it != inputs.myPeerID }
        val unread = others.associateWith { ChatUnread.countFor(it, inputs.unreadConversations) }
        val favorites = others.associateWith { peerID ->
            ChatFavorites.status(
                peerID = peerID,
                fingerprint = inputs.peerFingerprints[peerID],
                favoritePeers = inputs.favoritePeers,
                peerFavoritedUs = inputs.peerFavoritedUs,
                fallbacks = favoriteFallbacks
            )
        }
        val peers = others.sortedWith(order(inputs, unread, favorites))
        val offline = offlineFavorites(inputs, others)

        val names = peers.map { displayNameOf(it, inputs) }
        val offlineNames = offline.map { inputs.peerNicknames[it.noiseKeyHex] ?: it.nickname }
        // PeopleSection counts base names across every row it shows, connected and offline, before
        // deciding on suffixes.
        val baseNameCounts = (names + offlineNames).groupingBy { splitSuffix(it).first }.eachCount()
        fun shownName(name: String): Pair<String, String> {
            val (baseName, suffix) = splitSuffix(name)
            return truncateNickname(baseName) to if ((baseNameCounts[baseName] ?: 0) > 1) suffix else ""
        }

        val connectedRows = peers.zip(names) { peerID, name ->
            val (displayName, displaySuffix) = shownName(name)
            val rssi = inputs.peerRSSI[peerID]
            val favorite = favorites.getValue(peerID)
            Row(
                peerID = peerID,
                nickname = inputs.peerNicknames[peerID],
                displayName = displayName,
                displaySuffix = displaySuffix,
                rssi = rssi,
                signalBars = signalBars(rssi),
                connection = connection(
                    isWifiAware = peerID in inputs.wifiAwarePeerIDs,
                    isDirect = inputs.peerDirect[peerID] ?: isDirectFallback(peerID)
                ),
                unreadCount = unread.getValue(peerID),
                isFavorite = favorite.isFavorite,
                theyFavoritedUs = favorite.theyFavoritedUs
            )
        }
        val offlineRows = offline.zip(offlineNames) { favorite, name ->
            val (displayName, displaySuffix) = shownName(name)
            Row(
                peerID = favorite.noiseKeyHex,
                nickname = inputs.peerNicknames[favorite.noiseKeyHex],
                displayName = displayName,
                displaySuffix = displaySuffix,
                rssi = null,
                signalBars = null,
                connection = Connection.OFFLINE,
                // Its conversation is offline, so its badge is found by conversation ID rather
                // than by the connected peer upstream links it to.
                unreadCount = inputs.unreadConversations
                    .filter { it.conversationID.equals(favorite.conversationID, ignoreCase = true) }
                    .sumOf { it.unreadCount },
                isFavorite = true,
                theyFavoritedUs = favorite.theyFavoritedUs
            )
        }
        return connectedRows + offlineRows
    }

    /**
     * `offlineFavoriteRows`: our favourites with no listed conversation (their Noise key is not among
     * [Inputs.conversationAliases], #73) that no listed connected peer is — upstream's
     * `isFavoriteMappedToConnected` compares the record's Noise key, then its Nostr key, with the
     * connected peers', ignoring case.
     */
    private fun offlineFavorites(inputs: Inputs, connected: List<String>): List<ChatFavorites.Favorite> {
        if (inputs.ourFavorites.isEmpty()) return emptyList()
        val connectedNoiseKeys = connected.mapNotNullTo(HashSet()) { inputs.peerNoiseKeys[it]?.lowercase() }
        val connectedNostrKeys = connected.mapNotNullTo(HashSet()) { inputs.peerNostrKeys[it]?.lowercase() }
        return inputs.ourFavorites.filterNot { favorite ->
            favorite.noiseKeyHex.lowercase() in inputs.conversationAliases ||
                favorite.noiseKeyHex.lowercase() in connectedNoiseKeys ||
                favorite.nostrPubkeyHex?.lowercase()?.let { it in connectedNostrKeys } == true
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
     * then our favourites ([favorites]; being favourited by them is no key) — then nickname, else
     * peer ID, lowercased. Stable for ties.
     */
    private fun order(
        inputs: Inputs,
        unread: Map<String, Int>,
        favorites: Map<String, ChatFavorites.Status>
    ): Comparator<String> =
        compareByDescending<String> { peerID -> (unread[peerID] ?: 0) > 0 }
            .thenByDescending { peerID ->
                inputs.privateChats[peerID]?.maxByOrNull { it.timestamp }?.timestamp?.time ?: 0L
            }
            .thenByDescending { peerID -> favorites[peerID]?.isFavorite == true }
            .thenBy { (inputs.peerNicknames[it] ?: it).lowercase() }

    /** PeopleSection: nickname, else the last private message's sender, else the ID's prefix. */
    private fun displayNameOf(peerID: String, inputs: Inputs): String =
        inputs.peerNicknames[peerID]
            ?: inputs.privateChats[peerID]?.lastOrNull()?.sender
            ?: peerID.take(12)

    /** Upstream's precedence for a reachable peer (see [Connection]); a conversation row's too. */
    internal fun connection(isWifiAware: Boolean, isDirect: Boolean): Connection = when {
        isWifiAware -> Connection.WIFI_AWARE
        isDirect -> Connection.BLUETOOTH
        else -> Connection.ROUTED
    }
}
