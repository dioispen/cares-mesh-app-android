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
 *
 * Deliberately not (yet) mirrored:
 * - `PeopleSection` sorts unread private-message senders, then the most recent private chat,
 *   then favourites before its alphabetical key. Those keys arrive with the fields that make them
 *   visible (#55 private chats, #56 unread, #58 favourites); prepend them to [order] then.
 * - Offline favourites appended after the connected peers (#58); they must also be counted in the
 *   `#abcd` suffix de-duplication, as upstream counts them.
 * - Connected peers upstream moves into its "conversations" section; the Flutter chat has no such
 *   section yet, so every connected peer is listed.
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
        /** `ChatViewModel.privateChats`, for the display-name fallback only. */
        val privateChats: Map<String, List<BitchatMessage>>
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
        val connection: Connection
    )

    /** `PeerCounter`'s mesh count: `connectedPeers.filter { it != myPeerID }.size`. */
    fun onlineCount(inputs: Inputs): Int = inputs.connectedPeers.count { it != inputs.myPeerID }

    /**
     * The rows, in upstream order. [isDirectFallback] answers for peers `peerDirect` does not
     * cover yet (upstream asks `ChatViewModel.getMeshPeerInfo(id)?.isDirectConnection`).
     */
    fun rows(inputs: Inputs, isDirectFallback: (String) -> Boolean): List<Row> {
        val peers = inputs.connectedPeers.filter { it != inputs.myPeerID }.sortedWith(order(inputs))
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
                )
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

    /** PeopleSection's alphabetical key: nickname, else peer ID, lowercased. Stable for ties. */
    private fun order(inputs: Inputs): Comparator<String> =
        compareBy { (inputs.peerNicknames[it] ?: it).lowercase() }

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
