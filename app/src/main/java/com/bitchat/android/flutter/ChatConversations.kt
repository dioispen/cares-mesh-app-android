package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessageType
import com.bitchat.android.services.ContactIdentityResolver
import com.bitchat.android.services.ConversationStoreState
import com.bitchat.android.ui.ConversationSummary
import com.bitchat.android.ui.splitSuffix
import com.bitchat.android.ui.truncateNickname

/**
 * The native sheet's "Conversations" section, for the Flutter chat (#73): every private
 * conversation upstream keeps, whether its peer is on the mesh or not, so a chat that is read and
 * offline can still be opened.
 *
 * The list itself is upstream's: `ChatViewModel.conversations`, one [ConversationSummary] per
 * conversation (built from the stored history, so it survives a restart), already sorted by
 * `sortConversationSummaries` — connected first, then pinned, unread, latest activity, name. The
 * native sheet (`ui/MeshPeerListSheet.kt` `MeshPeerListSheet`) splits it into an online and an
 * offline group; the Flutter list deliberately keeps it as one list, in the same order, and marks
 * each row's presence instead. What `ConversationRow` and `ConversationSwipeItem` derive for a row
 * inside their Composables is reproduced here and fixed by `ChatConversationsTest`:
 *
 * - name: `splitSuffix(displayName)`, the base truncated (`truncateNickname`), the `#abcd` suffix
 *   always shown when the name has one (upstream resolves `displayName` itself: live announce,
 *   contact, stored name, latest sender).
 * - preview: upstream's text of the latest message and its kind (Dart words images, voice and files
 *   as upstream does), whether it was ours (the "You:" prefix), and its time.
 * - unread: the summary's count, the native row's `UnreadBadge`. Opening the conversation
 *   (`ChatViewModel.startPrivateChat`) clears it upstream; the list follows.
 * - presence: `isConnected` (upstream keeps a just-disconnected peer connected for a short grace
 *   window, so rows do not jump); while connected, how it is reached, by any of its IDs
 *   (`liveIdentityIDs` against the direct and Wi-Fi Aware peers, else the mesh peer info).
 * - star: `ConversationSwipeItem`'s fingerprint chain and fallbacks ([ChatFavorites.status]).
 *
 * Tapping a row opens the conversation by its ID — upstream's row runs
 * `showPrivateChatSheet(conversationID)`, whose sheet runs `startPrivateChat` with it; Dart's
 * private chat screen runs `chat_startPrivateChat` itself (#55), which loads the stored history.
 *
 * A peer listed here is not listed among the people ([identityAliases], see [ChatPeerList]).
 * Blocked peers' conversations are not listed ([ChatBlocking.visibleSummaries]).
 *
 * Not mirrored (out of scope for #73): the search field (8 or more conversations), swipe to delete
 * or mark read/unread, the actions menu, pinned and muted marks, the draft preview; the verified
 * badge and the avatar colour (the Flutter chat has neither); the Nostr globe (Nostr is disabled).
 */
object ChatConversations {

    /** The latest message's kind (`ConversationSummary.latestMessageType`); media are worded in Dart. */
    enum class PreviewType(val wire: String) {
        MESSAGE("message"),
        IMAGE("image"),
        AUDIO("audio"),
        FILE("file")
    }

    /**
     * Upstream's conversation store (`ChatViewModel.conversationStoreState`): while it is still
     * loading or failed, an empty list is not "no conversations yet" — the native section says so.
     */
    enum class StoreState(val wire: String) {
        LOADING("loading"),
        READY("ready"),
        ERROR("error")
    }

    /** The upstream state the rows are built from, read at one moment. */
    internal data class Inputs(
        /**
         * `ChatViewModel.conversations`, in upstream's order, without blocked peers'
         * ([ChatBlocking.visibleSummaries]).
         */
        val conversations: List<ConversationSummary>,
        /** `ChatViewModel.peerDirect`. */
        val peerDirect: Map<String, Boolean> = emptyMap(),
        /** Keys of `WifiAwareController.connectedPeers`. */
        val wifiAwarePeerIDs: Set<String> = emptySet(),
        /** `ChatViewModel.favoritePeers`: fingerprints we favourited. */
        val favoritePeers: Set<String> = emptySet(),
        /** `ChatViewModel.peerFavoritedUs`: fingerprints that favourited us. */
        val peerFavoritedUs: Set<String> = emptySet(),
        /** `ChatViewModel.peerFingerprints`: connected peer ID → fingerprint. */
        val peerFingerprints: Map<String, String> = emptyMap()
    )

    /** One row as the native section shows it. */
    data class Row(
        /** Upstream's conversation key; what the row opens the private chat with. */
        val conversationID: String,
        /** The name the row shows: `#abcd` split off, truncated. */
        val displayName: String,
        /** The `#abcd` suffix of upstream's name, "" when it has none. */
        val displaySuffix: String,
        /** Upstream's text of the latest message (whitespace folded, at most 240 chars); may be "". */
        val preview: String,
        val previewType: PreviewType,
        /** The latest message is ours. */
        val previewIsFromSelf: Boolean,
        /** When the latest message arrived (or was sent), epoch millis. */
        val timestamp: Long,
        /** Upstream's unread badge; 0 when nothing is unread. */
        val unreadCount: Int,
        /** Upstream marks the conversation's peer connected. */
        val isOnline: Boolean,
        /** How the peer is reached while online; [ChatPeerList.Connection.OFFLINE] exactly when not. */
        val connection: ChatPeerList.Connection,
        /** We favourited the peer. */
        val isFavorite: Boolean,
        /** They told us they favourited us. */
        val theyFavoritedUs: Boolean
    )

    /**
     * The rows, in upstream's order. [favoriteRelationship] is the favourites store's record for one
     * of a conversation's aliases ([ChatRecords.favoriteRelationship]); [isFavoriteFallback] is
     * upstream's `isFavorite(id)`, asked while no fingerprint is known; [isDirectFallback] is
     * `getMeshPeerInfo(id)?.isDirectConnection`, asked of a connected peer no alias shows direct.
     */
    internal fun rows(
        inputs: Inputs,
        favoriteRelationship: (String) -> ChatFavorites.Relationship? = { null },
        isFavoriteFallback: (String) -> Boolean = { false },
        isDirectFallback: (String) -> Boolean = { false }
    ): List<Row> {
        if (inputs.conversations.isEmpty()) return emptyList()
        val directIDs = inputs.peerDirect.filterValues { it }.keys.mapTo(HashSet()) { it.lowercase() }
        val wifiAwareIDs = inputs.wifiAwarePeerIDs.mapTo(HashSet()) { it.lowercase() }
        return inputs.conversations.map { summary ->
            val (baseName, suffix) = splitSuffix(summary.displayName)
            val favorite = favoriteStatus(summary, inputs, favoriteRelationship, isFavoriteFallback)
            Row(
                conversationID = summary.conversationID,
                displayName = truncateNickname(baseName),
                displaySuffix = suffix,
                preview = summary.latestMessagePreview,
                previewType = previewType(summary.latestMessageType),
                previewIsFromSelf = summary.latestMessageIsOutgoing,
                timestamp = summary.latestMessageAt,
                unreadCount = summary.unreadCount,
                isOnline = summary.isConnected,
                connection = connection(summary, directIDs, wifiAwareIDs, isDirectFallback),
                isFavorite = favorite.isFavorite,
                theyFavoritedUs = favorite.theyFavoritedUs
            )
        }
    }

    /**
     * `MeshPeerListSheet`'s `conversationIdentityAliases`: every ID the listed conversations are
     * known by (upstream lowercases them). A connected peer or offline favourite known by one of
     * them is listed in the conversations section, not among the people.
     */
    internal fun identityAliases(conversations: List<ConversationSummary>): Set<String> =
        conversations.flatMapTo(HashSet()) { it.identityAliases }

    fun storeState(state: ConversationStoreState): StoreState = when (state) {
        ConversationStoreState.Loading -> StoreState.LOADING
        ConversationStoreState.Ready -> StoreState.READY
        is ConversationStoreState.Error -> StoreState.ERROR
    }

    private fun previewType(type: BitchatMessageType): PreviewType = when (type) {
        BitchatMessageType.Message -> PreviewType.MESSAGE
        BitchatMessageType.Image -> PreviewType.IMAGE
        BitchatMessageType.Audio -> PreviewType.AUDIO
        BitchatMessageType.File -> PreviewType.FILE
    }

    /**
     * `ConversationRow`: offline unless upstream marks it connected; then Wi-Fi Aware, else direct
     * Bluetooth, else routed, matched by any of the conversation's IDs or its connected peer's.
     */
    private fun connection(
        summary: ConversationSummary,
        directIDs: Set<String>,
        wifiAwareIDs: Set<String>,
        isDirectFallback: (String) -> Boolean
    ): ChatPeerList.Connection {
        if (!summary.isConnected) return ChatPeerList.Connection.OFFLINE
        val liveIDs = summary.identityAliases + listOfNotNull(summary.connectedPeerID?.lowercase())
        return ChatPeerList.connection(
            isWifiAware = liveIDs.any(wifiAwareIDs::contains),
            isDirect = liveIDs.any(directIDs::contains) || summary.connectedPeerID?.let(isDirectFallback) == true
        )
    }

    /**
     * `ConversationSwipeItem`'s star: the fingerprint of the connected peer, else of any alias,
     * else the one a `contact_…` ID names, else the favourites store record's (looked up by alias);
     * without one, upstream asks `isFavorite` by the connected peer, else the conversation ID.
     */
    private fun favoriteStatus(
        summary: ConversationSummary,
        inputs: Inputs,
        favoriteRelationship: (String) -> ChatFavorites.Relationship?,
        isFavoriteFallback: (String) -> Boolean
    ): ChatFavorites.Status {
        val relationship = summary.identityAliases.firstNotNullOfOrNull(favoriteRelationship)
        val fingerprint = summary.connectedPeerID?.let(inputs.peerFingerprints::get)
            ?: summary.identityAliases.firstNotNullOfOrNull(inputs.peerFingerprints::get)
            ?: ContactIdentityResolver.fingerprintFromContactConversationId(summary.conversationID)
            ?: relationship?.fingerprint
        return ChatFavorites.status(
            peerID = summary.connectedPeerID ?: summary.conversationID,
            fingerprint = fingerprint,
            favoritePeers = inputs.favoritePeers,
            peerFavoritedUs = inputs.peerFavoritedUs,
            fallbacks = ChatFavorites.Fallbacks(
                isFavorite = isFavoriteFallback,
                theyFavoritedUs = { relationship?.theyFavoritedUs == true }
            )
        )
    }
}
