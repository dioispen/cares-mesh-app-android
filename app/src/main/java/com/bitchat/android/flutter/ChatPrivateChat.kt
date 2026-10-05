package com.bitchat.android.flutter

import com.bitchat.android.favorites.FavoritesPersistenceService
import com.bitchat.android.services.ContactDirectory
import com.bitchat.android.services.ContactIdentityResolver

/**
 * The private chat the native core has in focus, as the Flutter private chat screen shows it (#55).
 *
 * Which conversation is focused is upstream's call alone (`ChatViewModel.selectedPrivateChatPeer`,
 * set by `startPrivateChat`, `/m`, and cleared by `endPrivateChat`, `/block`, deletion...). What
 * upstream's own private chat screen (`ui/MeshPeerListSheet.kt` `PrivateChatSheet`) derives from it
 * inside its Composable, which the bridge cannot call, is reproduced here and fixed by
 * `ChatPrivateChatTest`:
 *
 * - the conversation's messages: `privateChats[ContactDirectory.resolve(id).conversationID]`, else
 *   `privateChats[id]` — Dart looks up [Focus.conversationID], then [Focus.peerID], in the
 *   `chat_private_chats` snapshot. The two differ while upstream is still re-keying a conversation
 *   (a peer's Noise key or favourite record turns its mesh peer ID into a `contact_…` ID).
 * - the title, [displayName].
 * - the header's favourite star (#58): [ChatFavorites.status] by [fingerprint]; tapping it runs
 *   `ChatViewModel.toggleFavorite` with the chat's ID (`chat_toggleFavorite`).
 *
 * Not mirrored: the `#geohash/@name` title of Nostr geohash DMs, and the "reachable over Nostr"
 * header icon of an offline mutual favourite (Nostr is disabled in this app); the star's wobble
 * when a peer favourites us (the star itself does change).
 */
object ChatPrivateChat {

    /** What upstream's contact records say about a selected private chat ID. */
    data class Contact(
        /** `ContactDirectory.resolve(id).conversationID`: the canonical conversation key. */
        val conversationID: String,
        /** `ContactDirectory.resolve(id).meshPeerID`: the mesh peer ID the contact is live under. */
        val meshPeerID: String?,
        /**
         * `ContactDirectory.resolve(id).displayName`: the live announce, else the favourite record,
         * else the nickname cached for the contact's fingerprint — how an offline peer keeps a name.
         */
        val displayName: String?,
        /** `FavoritesPersistenceService.getFavoriteStatus(id)?.peerNickname`. */
        val favoriteNickname: String?
    )

    /** The `chat_selected_private_peer` content while a private chat is focused. */
    data class Focus(
        /** `ChatViewModel.selectedPrivateChatPeer` exactly; sends are checked against this value. */
        val peerID: String,
        /** Where the conversation's messages are, see the class doc. */
        val conversationID: String,
        val displayName: String,
        /** The composer draft upstream keeps for this conversation; "" when there is none. */
        val draft: String,
        /** We favourited this peer: the header star is filled. */
        val isFavorite: Boolean = false,
        /** They told us they favourited us: the star is orange even when we have not. */
        val theyFavoritedUs: Boolean = false
    )

    /**
     * The fingerprint `PrivateChatSheet` looks the star up by: the live mesh peer's, else the
     * selected ID's own (`ChatViewModel.peerFingerprints`), else the one a `contact_…` ID names —
     * an offline contact's. Null when none is known.
     */
    fun fingerprint(peerID: String, contact: Contact, peerFingerprints: Map<String, String>): String? =
        contact.meshPeerID?.let(peerFingerprints::get)
            ?: peerFingerprints[peerID]
            ?: ContactIdentityResolver.fingerprintFromContactConversationId(peerID)

    /**
     * `PrivateChatSheet`'s title for [peerID]: the nickname announced under that ID, else under the
     * live mesh peer ID the contact resolves to, else the contact's name, else the favourite
     * record's nickname (unless blank or "Unknown"), else [fingerprintName] — upstream's
     * `ChatViewModel.resolvePeerDisplayNameForFingerprint`, which ends in the ID's first 8 chars.
     */
    fun displayName(
        peerID: String,
        contact: Contact,
        peerNicknames: Map<String, String>,
        fingerprintName: () -> String
    ): String =
        peerNicknames[peerID]
            ?: contact.meshPeerID?.let(peerNicknames::get)
            ?: contact.displayName
            ?: contact.favoriteNickname?.takeIf { it.isNotBlank() && !it.equals("Unknown", ignoreCase = true) }
            ?: fingerprintName()

    /** Upstream's records for [peerID]; an unreadable record counts as nothing known. */
    fun upstreamContact(peerID: String): Contact {
        val resolution = runCatching { ContactDirectory.resolve(peerID) }.getOrNull()
        val favorite = runCatching { FavoritesPersistenceService.shared.getFavoriteStatus(peerID) }.getOrNull()
        return Contact(
            conversationID = resolution?.conversationID ?: peerID,
            meshPeerID = resolution?.meshPeerID,
            displayName = resolution?.displayName,
            favoriteNickname = favorite?.peerNickname
        )
    }
}
