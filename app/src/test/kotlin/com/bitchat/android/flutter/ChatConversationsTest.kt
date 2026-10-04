package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessageType
import com.bitchat.android.services.ConversationStoreState
import com.bitchat.android.ui.ConversationSummary
import com.bitchat.android.ui.DirectMessageTransport
import com.bitchat.android.ui.sortConversationSummaries
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixes the native sheet's conversation rows as [ChatConversations] reproduces them (#73), so the
 * Flutter "對話" section shows what upstream's shows. Each test names the upstream source it
 * mirrors, all in `ui/MeshPeerListSheet.kt` unless said otherwise.
 */
class ChatConversationsTest {

    private fun rows(
        conversations: List<ConversationSummary>,
        peerDirect: Map<String, Boolean> = emptyMap(),
        wifiAwarePeerIDs: Set<String> = emptySet(),
        favoritePeers: Set<String> = emptySet(),
        peerFavoritedUs: Set<String> = emptySet(),
        peerFingerprints: Map<String, String> = emptyMap(),
        favoriteRelationship: (String) -> ChatFavorites.Relationship? = { null },
        isFavoriteFallback: (String) -> Boolean = { false },
        isDirectFallback: (String) -> Boolean = { false }
    ) = ChatConversations.rows(
        ChatConversations.Inputs(
            conversations = conversations,
            peerDirect = peerDirect,
            wifiAwarePeerIDs = wifiAwarePeerIDs,
            favoritePeers = favoritePeers,
            peerFavoritedUs = peerFavoritedUs,
            peerFingerprints = peerFingerprints
        ),
        favoriteRelationship = favoriteRelationship,
        isFavoriteFallback = isFavoriteFallback,
        isDirectFallback = isDirectFallback
    )

    // --- the list (MeshPeerListSheet: conversations, onlineConversations, offlineConversations) ----

    @Test
    fun `every conversation upstream keeps is a row, online and offline in one list, in upstream's order`() {
        // ChatViewModel.conversations is already sorted by sortConversationSummaries: connected
        // first, then pinned, unread, latest activity, name. The native sheet splits that list into
        // an online and an offline group; the Flutter list keeps it whole, in the same order.
        val upstream = sortConversationSummaries(
            listOf(
                summary(CONTACT_DORA, displayName = "dora", latestActivityOrder = 9),
                summary(CONTACT_ALICE, displayName = "alice", connectedPeerID = ALICE, latestActivityOrder = 1),
                summary(CONTACT_ERIN, displayName = "erin", unreadCount = 2, latestActivityOrder = 3)
            )
        )

        val ids = rows(upstream).map { it.conversationID }

        assertEquals(listOf(CONTACT_ALICE, CONTACT_ERIN, CONTACT_DORA), ids)
        assertEquals(upstream.map { it.conversationID }, ids)
    }

    @Test
    fun `no conversations is no rows`() {
        assertEquals(emptyList<ChatConversations.Row>(), rows(emptyList()))
    }

    // --- one row (ConversationRow) -------------------------------------------------------------

    @Test
    fun `a row carries upstream's name, preview, time and unread count as they are`() {
        val row = rows(
            listOf(
                summary(
                    CONTACT_DORA,
                    displayName = "dora",
                    unreadCount = 4,
                    latestMessageAt = 1_700_000_123_000L,
                    latestMessagePreview = "meet at the school gym",
                    latestMessageIsOutgoing = false
                )
            )
        ).single()

        assertEquals(CONTACT_DORA, row.conversationID)
        assertEquals("dora", row.displayName)
        assertEquals("", row.displaySuffix)
        assertEquals("meet at the school gym", row.preview)
        assertEquals(ChatConversations.PreviewType.MESSAGE, row.previewType)
        assertFalse(row.previewIsFromSelf)
        assertEquals(1_700_000_123_000L, row.timestamp)
        assertEquals(4, row.unreadCount)
    }

    @Test
    fun `our own latest message is marked, for the native "You" prefix`() {
        val row = rows(listOf(summary(CONTACT_DORA, latestMessageIsOutgoing = true))).single()

        assertTrue(row.previewIsFromSelf)
    }

    @Test
    fun `the name's hash suffix is split off and the base truncated like upstream's row`() {
        // ConversationRow: splitSuffix(displayName), truncateNickname(base); the suffix is always
        // shown, dimmed, when the name has one.
        val long = "x".repeat(40)
        val named = rows(
            listOf(
                summary(CONTACT_DORA, displayName = "dora#0a1b"),
                summary(CONTACT_ERIN, displayName = long)
            )
        )

        assertEquals("dora" to "#0a1b", named[0].displayName to named[0].displaySuffix)
        assertEquals(com.bitchat.android.ui.truncateNickname(long), named[1].displayName)
        assertEquals("", named[1].displaySuffix)
    }

    @Test
    fun `media previews carry their kind so Dart can word them as upstream does`() {
        val kinds = rows(
            listOf(
                summary(CONTACT_ALICE, latestMessageType = BitchatMessageType.Image),
                summary(CONTACT_DORA, latestMessageType = BitchatMessageType.Audio),
                summary(CONTACT_ERIN, latestMessageType = BitchatMessageType.File, latestMessagePreview = "map.pdf"),
                summary(CONTACT_FRED, latestMessageType = BitchatMessageType.Message)
            )
        ).map { it.previewType.wire }

        assertEquals(listOf("image", "audio", "file", "message"), kinds)
    }

    // --- presence (ConversationRow: isConnected, conversationTransportIcon) ----------------------

    @Test
    fun `a conversation upstream does not mark connected is offline`() {
        val row = rows(listOf(summary(CONTACT_DORA))).single()

        assertFalse(row.isOnline)
        assertEquals(ChatPeerList.Connection.OFFLINE, row.connection)
    }

    @Test
    fun `a connected conversation is reached the way its peer is - direct, Wi-Fi Aware or routed`() {
        val direct = summary(CONTACT_ALICE, connectedPeerID = ALICE, identityAliases = setOf(CONTACT_ALICE, ALICE))
        val aware = summary(CONTACT_ERIN, connectedPeerID = ERIN, identityAliases = setOf(CONTACT_ERIN, ERIN))
        val routed = summary(CONTACT_FRED, connectedPeerID = FRED, identityAliases = setOf(CONTACT_FRED, FRED))

        val connections = rows(
            listOf(direct, aware, routed),
            peerDirect = mapOf(ALICE to true, ERIN to true, FRED to false),
            wifiAwarePeerIDs = setOf(ERIN)
        ).map { it.isOnline to it.connection }

        assertEquals(
            listOf(
                true to ChatPeerList.Connection.BLUETOOTH,
                true to ChatPeerList.Connection.WIFI_AWARE,
                true to ChatPeerList.Connection.ROUTED
            ),
            connections
        )
    }

    @Test
    fun `directness is found under any of the conversation's IDs, any case, or asked of the mesh`() {
        // liveIdentityIDs = identityAliases + connectedPeerID; directPeerIdentityIDs lowercased;
        // else getMeshPeerInfo(connectedPeerID)?.isDirectConnection.
        val byAlias = summary(CONTACT_ALICE, connectedPeerID = ALICE, identityAliases = setOf(CONTACT_ALICE, NOISE_ALICE))
        val byMesh = summary(CONTACT_FRED, connectedPeerID = FRED, identityAliases = setOf(CONTACT_FRED))
        val asked = mutableListOf<String>()

        val connections = rows(
            listOf(byAlias, byMesh),
            peerDirect = mapOf(NOISE_ALICE.uppercase() to true),
            isDirectFallback = { id -> asked += id; id == FRED }
        ).map { it.connection }

        assertEquals(listOf(ChatPeerList.Connection.BLUETOOTH, ChatPeerList.Connection.BLUETOOTH), connections)
        assertEquals("the mesh is only asked when no alias is known to be direct", listOf(FRED), asked)
    }

    @Test
    fun `an offline conversation asks the mesh nothing`() {
        val asked = mutableListOf<String>()

        rows(listOf(summary(CONTACT_DORA)), isDirectFallback = { id -> asked += id; true })

        assertEquals(emptyList<String>(), asked)
    }

    // --- the star (ConversationSwipeItem: favoriteRelationship, fingerprint, isFavorite) -----------

    @Test
    fun `an online conversation's star is its peer's, by the peer's fingerprint`() {
        val row = rows(
            listOf(summary(CONTACT_ALICE, connectedPeerID = ALICE, identityAliases = setOf(CONTACT_ALICE, ALICE))),
            peerFingerprints = mapOf(ALICE to FP_ALICE),
            favoritePeers = setOf(FP_ALICE),
            peerFavoritedUs = setOf(FP_ALICE)
        ).single()

        assertTrue(row.isFavorite)
        assertTrue(row.theyFavoritedUs)
    }

    @Test
    fun `an offline contact's star is found by the fingerprint its conversation ID names`() {
        val fingerprint = CONTACT_DORA.removePrefix("contact_")

        val row = rows(listOf(summary(CONTACT_DORA)), favoritePeers = setOf(fingerprint)).single()

        assertTrue(row.isFavorite)
        assertFalse(row.theyFavoritedUs)
    }

    @Test
    fun `a conversation known by no fingerprint takes the favourites store's record`() {
        // A mesh-peer-ID conversation offline: its fingerprint is the store record's key's.
        val relationshipLookups = mutableListOf<String>()
        val row = rows(
            listOf(summary(FRED, identityAliases = setOf(FRED, NOISE_FRED))),
            favoritePeers = setOf(FP_FRED),
            favoriteRelationship = { alias ->
                relationshipLookups += alias
                if (alias == NOISE_FRED) ChatFavorites.Relationship(fingerprint = FP_FRED, theyFavoritedUs = true) else null
            }
        ).single()

        assertTrue(row.isFavorite)
        assertTrue("the record says they favourited us", row.theyFavoritedUs)
        assertEquals(setOf(FRED, NOISE_FRED), relationshipLookups.toSet())
    }

    @Test
    fun `without any fingerprint upstream is asked by the peer while online, else by the conversation`() {
        val asked = mutableListOf<String>()
        val favorites = rows(
            listOf(
                summary(BOB, connectedPeerID = BOB, identityAliases = setOf(BOB)),
                summary(FRED, identityAliases = setOf(FRED))
            ),
            isFavoriteFallback = { id -> asked += id; id == FRED }
        ).map { it.isFavorite }

        assertEquals(listOf(false, true), favorites)
        assertEquals(listOf(BOB, FRED), asked)
    }

    @Test
    fun `being favourited by them alone does not make them our favourite`() {
        val row = rows(
            listOf(summary(CONTACT_ALICE, connectedPeerID = ALICE, identityAliases = setOf(CONTACT_ALICE, ALICE))),
            peerFingerprints = mapOf(ALICE to FP_ALICE),
            peerFavoritedUs = setOf(FP_ALICE)
        ).single()

        assertFalse(row.isFavorite)
        assertTrue(row.theyFavoritedUs)
    }

    // --- identity aliases (MeshPeerListSheet: conversationIdentityAliases) -----------------------

    @Test
    fun `the aliases a peer is matched against are every listed conversation's`() {
        val aliases = ChatConversations.identityAliases(
            listOf(
                summary(CONTACT_ALICE, identityAliases = setOf(CONTACT_ALICE, ALICE, NOISE_ALICE)),
                summary(CONTACT_DORA, identityAliases = setOf(CONTACT_DORA))
            )
        )

        assertEquals(setOf(CONTACT_ALICE, ALICE, NOISE_ALICE, CONTACT_DORA), aliases)
    }

    // --- the store (MeshPeerListSheet: conversationStoreState) ------------------------------------

    @Test
    fun `the store's state is carried for the native loading and error notes`() {
        assertEquals(ChatConversations.StoreState.LOADING, ChatConversations.storeState(ConversationStoreState.Loading))
        assertEquals(ChatConversations.StoreState.READY, ChatConversations.storeState(ConversationStoreState.Ready))
        assertEquals(ChatConversations.StoreState.ERROR, ChatConversations.storeState(ConversationStoreState.Error("disk")))
        assertEquals(
            listOf("loading", "ready", "error"),
            ChatConversations.StoreState.entries.map { it.wire }
        )
    }

    private fun summary(
        conversationID: String,
        displayName: String = "peer",
        unreadCount: Int = 0,
        latestMessageAt: Long = 1_700_000_000_000L,
        latestActivityOrder: Long = 1L,
        latestMessageType: BitchatMessageType = BitchatMessageType.Message,
        latestMessagePreview: String = "hi",
        latestMessageIsOutgoing: Boolean = false,
        identityAliases: Set<String> = setOf(conversationID),
        connectedPeerID: String? = null
    ) = ConversationSummary(
        conversationID = conversationID,
        displayName = displayName,
        unreadCount = unreadCount,
        latestMessageAt = latestMessageAt,
        latestActivityOrder = latestActivityOrder,
        latestMessageType = latestMessageType,
        latestMessagePreview = latestMessagePreview,
        latestMessageIsOutgoing = latestMessageIsOutgoing,
        transport = DirectMessageTransport.MESH,
        nostrPubkey = null,
        identityAliases = identityAliases,
        isConnected = connectedPeerID != null,
        connectedPeerID = connectedPeerID
    )

    private companion object {
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        const val ERIN = "5555555555555555"
        const val FRED = "7777777777777777"
        val CONTACT_ALICE = "contact_" + "a".repeat(64)
        val CONTACT_DORA = "contact_" + "d".repeat(64)
        val CONTACT_ERIN = "contact_" + "e".repeat(64)
        val CONTACT_FRED = "contact_" + "7".repeat(64)
        val FP_ALICE = "f".repeat(64)
        val FP_FRED = "9".repeat(64)
        val NOISE_ALICE = "a".repeat(63) + "1"
        val NOISE_FRED = "7".repeat(63) + "1"
    }
}
