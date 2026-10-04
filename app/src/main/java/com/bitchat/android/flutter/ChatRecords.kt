package com.bitchat.android.flutter

import android.content.Context
import com.bitchat.android.favorites.FavoritesChangeListener
import com.bitchat.android.favorites.FavoritesPersistenceService
import com.bitchat.android.identity.SecureIdentityStateManager
import com.bitchat.android.services.ContactDirectory
import com.bitchat.android.services.ContactIdentityResolver
import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.ui.DataManager

/**
 * Upstream records the chat bridge reads on demand, outside `ChatViewModel`'s flows (#58): the
 * favourites store and the block list. Read-only — every change goes through upstream's own
 * methods (`toggleFavorite`, `/block`, `/unblock`).
 *
 * Reads may touch disk and the keystore (the encrypted identity store, the block list in
 * preferences), so [ChatBridge] makes them only while building a snapshot on its snapshot
 * dispatcher — never on the main thread — and one at a time. [addFavoritesListener] is the
 * exception: it only registers a listener.
 */
interface ChatRecords {

    /** Our favourites in upstream's store, in its order (`FavoritesPersistenceService.getOurFavorites`). */
    fun ourFavorites(): List<ChatFavorites.Favorite>

    /** `FavoritesPersistenceService.getFavoriteStatus(peerID)?.theyFavoritedUs`. */
    fun theyFavoritedUs(peerID: String): Boolean

    /** The hex Nostr key upstream has indexed for a mesh peer ID (`findNostrPubkeyForPeerID`). */
    fun nostrPubkeyHex(peerID: String): String?

    /** The Noise key cached for a mesh peer ID (`SecureIdentityStateManager.getCachedNoiseKey`). */
    fun cachedNoiseKeyHex(peerID: String): String?

    /** Calls [onChange] whenever the favourites store changes; the answer removes the listener. */
    fun addFavoritesListener(onChange: () -> Unit): () -> Unit

    /** Whether upstream's block list has anyone at all; while not, no peer is blocked. */
    fun hasBlockedPeers(): Boolean

    /** Upstream's own decision (`PrivateChatManager.isPeerBlocked`) for a peer or conversation ID. */
    fun isPeerBlocked(peerID: String): Boolean
}

/**
 * [ChatRecords] read from the live upstream objects. Every read is defensive: a record that cannot
 * be read counts as nothing known (no favourite, not blocked), as the native UI treats it.
 *
 * Not thread-safe (its [DataManager] reloads the block list into a plain set): call it from one
 * thread at a time, as [ChatBridge]'s snapshot dispatcher does. Constructing it reads nothing; the
 * identity store and preferences are opened on the first read.
 */
class UpstreamChatRecords(
    private val chatViewModel: ChatViewModel,
    context: Context = chatViewModel.getApplication()
) : ChatRecords {

    private val appContext = context.applicationContext

    // The same stores upstream's own readers open: PeopleSection keeps one identity manager for its
    // cached Noise keys; DataManager reads the block list from bitchat_prefs, where
    // PrivateChatManager's DataManager saves every change at once.
    private val identityManager by lazy { runCatching { SecureIdentityStateManager(appContext) }.getOrNull() }
    private val dataManager by lazy { DataManager(appContext) }

    private val favorites: FavoritesPersistenceService?
        get() = runCatching { FavoritesPersistenceService.shared }.getOrNull()

    override fun ourFavorites(): List<ChatFavorites.Favorite> =
        runCatching {
            favorites?.getOurFavorites().orEmpty().map { relationship ->
                val noiseKeyHex = ContactIdentityResolver.noiseKeyHex(relationship.peerNoisePublicKey)
                ChatFavorites.Favorite(
                    noiseKeyHex = noiseKeyHex,
                    nostrPubkeyHex = relationship.peerNostrPublicKey?.let(ContactIdentityResolver::nostrPubkeyHex),
                    nickname = relationship.peerNickname,
                    theyFavoritedUs = relationship.theyFavoritedUs,
                    conversationID = ContactDirectory.canonicalConversationId(noiseKeyHex)
                )
            }
        }.getOrDefault(emptyList())

    override fun theyFavoritedUs(peerID: String): Boolean =
        runCatching { favorites?.getFavoriteStatus(peerID)?.theyFavoritedUs == true }.getOrDefault(false)

    override fun nostrPubkeyHex(peerID: String): String? =
        runCatching {
            favorites?.findNostrPubkeyForPeerID(peerID)?.let(ContactIdentityResolver::nostrPubkeyHex)
        }.getOrNull()

    override fun cachedNoiseKeyHex(peerID: String): String? =
        runCatching { identityManager?.getCachedNoiseKey(peerID) }.getOrNull()

    override fun addFavoritesListener(onChange: () -> Unit): () -> Unit {
        val store = favorites ?: return {}
        val listener = object : FavoritesChangeListener {
            override fun onFavoriteChanged(noiseKeyHex: String) = onChange()
            override fun onAllCleared() = onChange()
        }
        runCatching { store.addListener(listener) }
        return { runCatching { store.removeListener(listener) } }
    }

    override fun hasBlockedPeers(): Boolean =
        runCatching { dataManager.loadBlockedUsers(); dataManager.blockedUsers.isNotEmpty() }.getOrDefault(false)

    override fun isPeerBlocked(peerID: String): Boolean =
        runCatching { chatViewModel.privateChatManager.isPeerBlocked(peerID) }.getOrDefault(false)
}
