package com.bitchat.android.flutter

/**
 * Favourites as the native chat shows them, for the Flutter chat (#58).
 *
 * Toggling is upstream's alone (`ChatViewModel.toggleFavorite`, through `chat_toggleFavorite`); the
 * bridge only reads what upstream records:
 * - `ChatViewModel.favoritePeers`: the fingerprints we favourited (`DataManager`, saved in
 *   `bitchat_prefs`).
 * - `ChatViewModel.peerFavoritedUs`: the fingerprints of peers that told us they favourited us.
 * - upstream's favourites store (`FavoritesPersistenceService`, encrypted prefs): one record per
 *   Noise key with both directions and the peer's nickname — how an offline favourite keeps its
 *   name and stays reachable. Read through [ChatRecords].
 *
 * Both survive a restart: `ChatViewModel` reloads them when it is created, in the Flutter entry as
 * in `MainActivity`.
 *
 * Upstream decides a peer's star inside its Composables; the rule is reproduced in [status] and
 * fixed by `ChatFavoritesTest`. The native star has three looks, which Dart reproduces: none or
 * grey outline (no relation), orange outline (they favourited us), filled orange (we favourited
 * them, mutual or not) — `PeerAvatar`, `PrivateChatSheet`'s `favoriteStarTint`.
 */
object ChatFavorites {

    /** Both directions of a favourite relationship, as one peer's star shows them. */
    data class Status(
        /** We favourited them. */
        val isFavorite: Boolean,
        /** They told us they favourited us. */
        val theyFavoritedUs: Boolean
    )

    /** Upstream's by-ID answers, asked for a peer whose fingerprint is not known (yet). */
    class Fallbacks(
        /** `ChatViewModel.isFavorite(id)`. */
        val isFavorite: (String) -> Boolean = { false },
        /** `FavoritesPersistenceService.getFavoriteStatus(id)?.theyFavoritedUs`. */
        val theyFavoritedUs: (String) -> Boolean = { false }
    ) {
        companion object {
            val NONE = Fallbacks()
        }
    }

    /**
     * One of our favourites in upstream's store (`FavoritesPersistenceService.getOurFavorites`),
     * reduced to what the peer list needs.
     */
    data class Favorite(
        /** The record's key; upstream opens the private chat with it while the peer is offline. */
        val noiseKeyHex: String,
        /** Hex Nostr key the peer told us, if any; upstream also matches connected peers by it. */
        val nostrPubkeyHex: String?,
        /** The nickname recorded with the favourite. */
        val nickname: String,
        val theyFavoritedUs: Boolean,
        /** Upstream's conversation ID for the Noise key (`ContactDirectory.canonicalConversationId`). */
        val conversationID: String
    )

    /**
     * A record of upstream's favourites store (`FavoritesPersistenceService.getFavoriteStatus`), as a
     * conversation row's star reads it (#73, `ConversationSwipeItem`'s `favoriteRelationship`): the
     * fingerprint of its Noise key, and whether they favourited us.
     */
    data class Relationship(val fingerprint: String, val theyFavoritedUs: Boolean)

    /**
     * A peer's star, the rule `PeopleSection` (`peerFavoriteStates`, `peerTheyFavoritedUsStates`),
     * `PrivateChatSheet` (`isFavorite`, `theyFavoritedUs`) and `ConversationSwipeItem` share:
     * - favourite: with a [fingerprint], whether `favoritePeers` has it — and only that; without
     *   one, upstream asks `isFavorite` by the ID.
     * - favourited us: `peerFavoritedUs` has the fingerprint, or the favourites store says so for
     *   the ID.
     * They differ only in where the fingerprint comes from (see [ChatPeerList],
     * [ChatPrivateChat.fingerprint] and [ChatConversations]).
     */
    fun status(
        peerID: String,
        fingerprint: String?,
        favoritePeers: Set<String>,
        peerFavoritedUs: Set<String>,
        fallbacks: Fallbacks
    ): Status = Status(
        isFavorite = if (fingerprint != null) fingerprint in favoritePeers else fallbacks.isFavorite(peerID),
        theyFavoritedUs = (fingerprint != null && fingerprint in peerFavoritedUs) || fallbacks.theyFavoritedUs(peerID)
    )
}
