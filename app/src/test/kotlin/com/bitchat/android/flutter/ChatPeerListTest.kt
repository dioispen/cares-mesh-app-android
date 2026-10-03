package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/**
 * Fixes the upstream peer-list rules [ChatPeerList] reproduces, so the Flutter list shows what the
 * native one shows. Each test names the upstream source it mirrors.
 */
class ChatPeerListTest {

    private fun inputs(
        connectedPeers: List<String>,
        peerNicknames: Map<String, String> = emptyMap(),
        peerRSSI: Map<String, Int> = emptyMap(),
        peerDirect: Map<String, Boolean> = emptyMap(),
        wifiAwarePeerIDs: Set<String> = emptySet(),
        privateChats: Map<String, List<BitchatMessage>> = emptyMap(),
        unreadConversations: List<ChatUnread.Conversation> = emptyList(),
        favoritePeers: Set<String> = emptySet(),
        peerFavoritedUs: Set<String> = emptySet(),
        peerFingerprints: Map<String, String> = emptyMap(),
        ourFavorites: List<ChatFavorites.Favorite> = emptyList(),
        peerNoiseKeys: Map<String, String> = emptyMap(),
        peerNostrKeys: Map<String, String> = emptyMap()
    ) = ChatPeerList.Inputs(
        myPeerID = ME,
        connectedPeers = connectedPeers,
        peerNicknames = peerNicknames,
        peerRSSI = peerRSSI,
        peerDirect = peerDirect,
        wifiAwarePeerIDs = wifiAwarePeerIDs,
        privateChats = privateChats,
        unreadConversations = unreadConversations,
        favoritePeers = favoritePeers,
        peerFavoritedUs = peerFavoritedUs,
        peerFingerprints = peerFingerprints,
        ourFavorites = ourFavorites,
        peerNoiseKeys = peerNoiseKeys,
        peerNostrKeys = peerNostrKeys
    )

    private fun rows(
        inputs: ChatPeerList.Inputs,
        favoriteFallbacks: ChatFavorites.Fallbacks = ChatFavorites.Fallbacks.NONE,
        isDirectFallback: (String) -> Boolean = { false }
    ) = ChatPeerList.rows(inputs, favoriteFallbacks, isDirectFallback)

    private fun row(inputs: ChatPeerList.Inputs, isDirectFallback: (String) -> Boolean = { false }) =
        rows(inputs, isDirectFallback = isDirectFallback).single()

    // --- online count (ChatHeader.MainHeader → PeerCounter) --------------------------------------

    @Test
    fun `online count is every connected peer but ourselves`() {
        val count = ChatPeerList.onlineCount(inputs(connectedPeers = listOf(ALICE, ME, BOB)))

        assertEquals(2, count)
    }

    @Test
    fun `online count is zero when nobody is connected`() {
        assertEquals(0, ChatPeerList.onlineCount(inputs(connectedPeers = emptyList())))
        assertEquals(0, ChatPeerList.onlineCount(inputs(connectedPeers = listOf(ME))))
    }

    @Test
    fun `we are not listed among the peers`() {
        val ids = rows(inputs(connectedPeers = listOf(ALICE, ME))).map { it.peerID }

        assertEquals(listOf(ALICE), ids)
    }

    @Test
    fun `the list has one row per peer the online count counts`() {
        val state = inputs(connectedPeers = listOf(ALICE, ME, BOB, CAROL))

        assertEquals(ChatPeerList.onlineCount(state), rows(state).size)
    }

    // --- order (MeshPeerListSheet.PeopleSection sortedPeers, alphabetical key) ---------------------

    @Test
    fun `peers are sorted by nickname, ignoring case`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB, CAROL),
            peerNicknames = mapOf(ALICE to "zoe", BOB to "Bob", CAROL to "amy")
        )

        assertEquals(listOf("amy", "Bob", "zoe"), rows(state).map { it.displayName })
    }

    @Test
    fun `a peer without a nickname sorts by its peer ID`() {
        // Upstream's key is `peerNicknames[id] ?: id`, not the display-name fallback chain.
        val state = inputs(
            connectedPeers = listOf(BOB, CAROL, ALICE),
            peerNicknames = mapOf(BOB to "zed", CAROL to "0-first")
        )

        assertEquals(listOf(CAROL, ALICE, BOB), rows(state).map { it.peerID })
    }

    @Test
    fun `peers sorting equal keep the upstream list order`() {
        val state = inputs(
            connectedPeers = listOf(BOB, ALICE),
            peerNicknames = mapOf(ALICE to "sam", BOB to "SAM")
        )

        assertEquals(listOf(BOB, ALICE), rows(state).map { it.peerID })
    }

    // --- order (PeopleSection sortedPeers, "most recent DM" key, #55) ------------------------------

    @Test
    fun `a peer with a more recent private message is listed first`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB, CAROL),
            peerNicknames = mapOf(ALICE to "amy", BOB to "bob", CAROL to "cat"),
            privateChats = mapOf(
                BOB to listOf(dm("bob", at = 2_000L)),
                CAROL to listOf(dm("cat", at = 5_000L), dm("me", at = 1_000L))
            )
        )

        assertEquals(listOf(CAROL, BOB, ALICE), rows(state).map { it.peerID })
    }

    @Test
    fun `the recency key is upstream's lookup by mesh peer ID`() {
        // Upstream reads privateChats[peerID]; a conversation already re-keyed to a contact_ ID
        // no longer lifts its peer, in the native list as here.
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB),
            peerNicknames = mapOf(ALICE to "amy", BOB to "bob"),
            privateChats = mapOf("contact_${"b".repeat(64)}" to listOf(dm("bob", at = 9_000L)))
        )

        assertEquals(listOf(ALICE, BOB), rows(state).map { it.peerID })
    }

    // --- unread (#56: conversation row badge, "unread first" sort key) ----------------------------

    @Test
    fun `a peer's unread count is the badge of its online conversation`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB),
            peerNicknames = mapOf(ALICE to "amy", BOB to "bob"),
            unreadConversations = listOf(
                ChatUnread.Conversation(CONTACT, BOB, 4),
                ChatUnread.Conversation("contact_${"f".repeat(64)}", null, 7)
            )
        )

        assertEquals(mapOf(ALICE to 0, BOB to 4), rows(state).associate { it.peerID to it.unreadCount })
    }

    @Test
    fun `a peer with unread messages is listed first, even before a more recent private chat`() {
        // PeopleSection's first key (unread DM senders first); the native conversation rows also
        // put unread conversations ahead of the more recent ones.
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB, CAROL),
            peerNicknames = mapOf(ALICE to "amy", BOB to "bob", CAROL to "cat"),
            privateChats = mapOf(ALICE to listOf(dm("amy", at = 9_000L))),
            unreadConversations = listOf(ChatUnread.Conversation(CONTACT, CAROL, 1))
        )

        assertEquals(listOf(CAROL, ALICE, BOB), rows(state).map { it.peerID })
    }

    @Test
    fun `peers with unread messages keep the recency and name order among themselves`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB, CAROL),
            peerNicknames = mapOf(ALICE to "amy", BOB to "bob", CAROL to "cat"),
            privateChats = mapOf(CAROL to listOf(dm("cat", at = 9_000L))),
            unreadConversations = listOf(
                ChatUnread.Conversation("contact_${"a".repeat(64)}", ALICE, 1),
                ChatUnread.Conversation("contact_${"b".repeat(64)}", BOB, 9),
                ChatUnread.Conversation("contact_${"c".repeat(64)}", CAROL, 2)
            )
        )

        // The key is "has unread", not how many: carol by recency, then amy and bob by name.
        assertEquals(listOf(CAROL, ALICE, BOB), rows(state).map { it.peerID })
    }

    // --- names (PeopleSection displayName, PeerItem splitSuffix / truncateNickname) ---------------

    @Test
    fun `display name is the announced nickname`() {
        val peer = row(inputs(connectedPeers = listOf(ALICE), peerNicknames = mapOf(ALICE to "alice")))

        assertEquals("alice", peer.displayName)
        assertEquals("alice", peer.nickname)
    }

    @Test
    fun `without a nickname the display name is the last private message's sender`() {
        val peer = row(
            inputs(
                connectedPeers = listOf(ALICE),
                privateChats = mapOf(ALICE to listOf(dm("older"), dm("alice-from-dm")))
            )
        )

        assertEquals("alice-from-dm", peer.displayName)
        assertNull("nickname stays the raw announce value", peer.nickname)
    }

    @Test
    fun `without a nickname or private chat the display name is the peer ID prefix`() {
        val peer = row(inputs(connectedPeers = listOf(ALICE)))

        assertEquals(ALICE.take(12), peer.displayName)
        assertNull(peer.nickname)
    }

    @Test
    fun `long nicknames are truncated like upstream`() {
        val peer = row(inputs(connectedPeers = listOf(ALICE), peerNicknames = mapOf(ALICE to "a".repeat(40))))

        assertEquals("a".repeat(15), peer.displayName)
        assertEquals("a".repeat(40), peer.nickname)
    }

    @Test
    fun `a hash suffix is hidden when the base name is unique`() {
        val peer = row(inputs(connectedPeers = listOf(ALICE), peerNicknames = mapOf(ALICE to "alice#beef")))

        assertEquals("alice", peer.displayName)
        assertEquals("", peer.displaySuffix)
        assertEquals("alice#beef", peer.nickname)
    }

    @Test
    fun `hash suffixes are shown when peers share a base name`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB, CAROL),
            peerNicknames = mapOf(ALICE to "sam#0a1b", BOB to "sam#ffff", CAROL to "carol#1234")
        )

        assertEquals(
            listOf("carol" to "", "sam" to "#0a1b", "sam" to "#ffff"),
            rows(state).map { it.displayName to it.displaySuffix }
        )
    }

    @Test
    fun `a name that merely contains a hash is not split`() {
        val peer = row(inputs(connectedPeers = listOf(ALICE), peerNicknames = mapOf(ALICE to "team#1")))

        assertEquals("team#1", peer.displayName)
        assertEquals("", peer.displaySuffix)
    }

    // --- connection (PeerItem isDirect, meshConnectionDescription precedence) --------------------

    @Test
    fun `a directly connected peer is on bluetooth`() {
        val peer = row(inputs(connectedPeers = listOf(ALICE), peerDirect = mapOf(ALICE to true)))

        assertEquals(ChatPeerList.Connection.BLUETOOTH, peer.connection)
    }

    @Test
    fun `a peer reached through other peers is routed`() {
        val peer = row(inputs(connectedPeers = listOf(ALICE), peerDirect = mapOf(ALICE to false)))

        assertEquals(ChatPeerList.Connection.ROUTED, peer.connection)
    }

    @Test
    fun `directness not yet in peerDirect falls back to the mesh peer info`() {
        // peerDirect is refreshed once a second; upstream asks getMeshPeerInfo in between.
        val asked = mutableListOf<String>()
        val state = inputs(connectedPeers = listOf(ALICE, BOB), peerDirect = mapOf(BOB to false))

        val connections = rows(state) { id -> asked += id; true }.associate { it.peerID to it.connection }

        assertEquals(listOf(ALICE), asked)
        assertEquals(ChatPeerList.Connection.BLUETOOTH, connections[ALICE])
        assertEquals(ChatPeerList.Connection.ROUTED, connections[BOB])
    }

    @Test
    fun `wifi aware wins over bluetooth and routing`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB),
            peerDirect = mapOf(ALICE to true, BOB to false),
            wifiAwarePeerIDs = setOf(ALICE, BOB)
        )

        assertEquals(
            listOf(ChatPeerList.Connection.WIFI_AWARE, ChatPeerList.Connection.WIFI_AWARE),
            rows(state).map { it.connection }
        )
    }

    @Test
    fun `connection wire names are what Dart parses`() {
        assertEquals(
            listOf("wifiAware", "bluetooth", "routed", "offline"),
            ChatPeerList.Connection.values().map { it.wire }
        )
    }

    // --- favourites (#58: PeopleSection peerFavoriteStates / peerTheyFavoritedUsStates) ----------

    @Test
    fun `rows carry upstream's favourite and favourited-us state, by fingerprint`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB, CAROL),
            peerNicknames = mapOf(ALICE to "alice", BOB to "bob", CAROL to "carol"),
            peerFingerprints = mapOf(ALICE to FP_ALICE, BOB to FP_BOB, CAROL to FP_CAROL),
            favoritePeers = setOf(FP_ALICE, FP_CAROL),
            peerFavoritedUs = setOf(FP_BOB, FP_CAROL)
        )

        assertEquals(
            mapOf(ALICE to (true to false), BOB to (false to true), CAROL to (true to true)),
            rows(state).associate { it.peerID to (it.isFavorite to it.theyFavoritedUs) }
        )
    }

    @Test
    fun `a peer without a known fingerprint is looked up by its ID, as upstream does`() {
        val asked = mutableListOf<String>()
        val state = inputs(connectedPeers = listOf(ALICE, BOB), peerFingerprints = mapOf(BOB to FP_BOB))

        val byId = rows(
            state,
            ChatFavorites.Fallbacks(
                isFavorite = { id -> asked += "isFavorite:$id"; id == ALICE },
                theyFavoritedUs = { id -> id == ALICE }
            )
        ).associateBy { it.peerID }

        assertTrue(byId.getValue(ALICE).isFavorite)
        assertTrue(byId.getValue(ALICE).theyFavoritedUs)
        assertFalse(byId.getValue(BOB).isFavorite)
        assertEquals("only the peer without a fingerprint", listOf("isFavorite:$ALICE"), asked)
    }

    @Test
    fun `favourites are listed after more recent private chats and before the alphabetical order`() {
        // sortedPeers: unread first, then the most recent DM, then favourites, then by name.
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB, CAROL),
            peerNicknames = mapOf(ALICE to "amy", BOB to "bob", CAROL to "zoe"),
            peerFingerprints = mapOf(ALICE to FP_ALICE, BOB to FP_BOB, CAROL to FP_CAROL),
            favoritePeers = setOf(FP_CAROL),
            privateChats = mapOf(BOB to listOf(dm("bob", at = 2_000L)))
        )

        assertEquals(listOf("bob", "zoe", "amy"), rows(state).map { it.displayName })
    }

    @Test
    fun `unread messages still come before a favourite`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB),
            peerNicknames = mapOf(ALICE to "amy", BOB to "bob"),
            peerFingerprints = mapOf(ALICE to FP_ALICE),
            favoritePeers = setOf(FP_ALICE),
            unreadConversations = listOf(ChatUnread.Conversation(CONTACT, BOB, 1))
        )

        assertEquals(listOf(BOB, ALICE), rows(state).map { it.peerID })
    }

    @Test
    fun `being favourited by a peer does not move it`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB),
            peerNicknames = mapOf(ALICE to "amy", BOB to "zoe"),
            peerFingerprints = mapOf(BOB to FP_BOB),
            peerFavoritedUs = setOf(FP_BOB)
        )

        assertEquals(listOf("amy", "zoe"), rows(state).map { it.displayName })
    }

    // --- offline favourites (#58: PeopleSection offlineFavoriteRows) ------------------------------

    @Test
    fun `offline favourites are appended after the connected peers, in the store's order`() {
        val state = inputs(
            connectedPeers = listOf(ALICE, ME),
            peerNicknames = mapOf(ALICE to "zed"),
            ourFavorites = listOf(favorite(NOISE_DORA, "dora"), favorite(NOISE_ERIN, "erin", theyFavoritedUs = true))
        )

        val rows = rows(state)

        // The row is keyed by the favourite's Noise key: what upstream opens the private chat with.
        assertEquals(listOf(ALICE, NOISE_DORA, NOISE_ERIN), rows.map { it.peerID })
        val dora = rows[1]
        assertEquals("dora", dora.displayName)
        assertNull("no announce under that key", dora.nickname)
        assertNull(dora.rssi)
        assertNull(dora.signalBars)
        assertEquals(ChatPeerList.Connection.OFFLINE, dora.connection)
        assertTrue("every offline row is one of our favourites", dora.isFavorite)
        assertFalse(dora.theyFavoritedUs)
        assertTrue("the record says whether they favourited us", rows[2].theyFavoritedUs)
    }

    @Test
    fun `the online count leaves offline favourites out`() {
        val state = inputs(connectedPeers = listOf(ALICE, ME), ourFavorites = listOf(favorite(NOISE_DORA, "dora")))

        assertEquals(1, ChatPeerList.onlineCount(state))
        assertEquals(2, rows(state).size)
    }

    @Test
    fun `a favourite on the mesh is listed once, as its connected row`() {
        // isFavoriteMappedToConnected: its Noise key, or its Nostr key, is a connected peer's.
        val state = inputs(
            connectedPeers = listOf(ALICE, BOB),
            peerNicknames = mapOf(ALICE to "alice", BOB to "bob"),
            peerNoiseKeys = mapOf(ALICE to NOISE_DORA.uppercase()),
            peerNostrKeys = mapOf(BOB to NOSTR_ERIN),
            ourFavorites = listOf(
                favorite(NOISE_DORA, "dora"),
                favorite(NOISE_ERIN, "erin", nostrPubkeyHex = NOSTR_ERIN.uppercase()),
                favorite(NOISE_FRED, "fred")
            )
        )

        assertEquals(listOf(ALICE, BOB, NOISE_FRED), rows(state).map { it.peerID })
    }

    @Test
    fun `offline favourites count when deciding on hash suffixes`() {
        // PeopleSection counts base names across connected and offline rows alike.
        val state = inputs(
            connectedPeers = listOf(ALICE),
            peerNicknames = mapOf(ALICE to "sam#0a1b"),
            ourFavorites = listOf(favorite(NOISE_DORA, "sam#ffff"), favorite(NOISE_ERIN, "solo#1234"))
        )

        assertEquals(
            listOf("sam" to "#0a1b", "sam" to "#ffff", "solo" to ""),
            rows(state).map { it.displayName to it.displaySuffix }
        )
    }

    @Test
    fun `an offline favourite's name is truncated like any row's`() {
        val state = inputs(connectedPeers = emptyList(), ourFavorites = listOf(favorite(NOISE_DORA, "d".repeat(40))))

        assertEquals("d".repeat(15), row(state).displayName)
    }

    @Test
    fun `an offline favourite's badge is its conversation's unread count`() {
        val state = inputs(
            connectedPeers = emptyList(),
            ourFavorites = listOf(favorite(NOISE_DORA, "dora")),
            unreadConversations = listOf(ChatUnread.Conversation(CONTACT_DORA.uppercase(), null, 4))
        )

        assertEquals(4, row(state).unreadCount)
    }

    // --- signal (PeerManager RSSI, MeshPeerListSheet.convertRSSIToSignalStrength) -----------------

    @Test
    fun `rssi is carried in dBm, null when upstream has none`() {
        val state = inputs(connectedPeers = listOf(ALICE, BOB), peerRSSI = mapOf(ALICE to -67))

        val byId = rows(state).associateBy { it.peerID }

        assertEquals(-67, byId.getValue(ALICE).rssi)
        assertNull(byId.getValue(BOB).rssi)
        assertNull(byId.getValue(BOB).signalBars)
    }

    @Test
    fun `signal bars follow upstream's rssi bands`() {
        // convertRSSIToSignalStrength: >= -40 → 100, >= -55 → 85, >= -70 → 70, >= -85 → 50,
        // >= -100 → 25, else 0; its doc maps 99-100 → 3 bars, 66-98 → 2, 33-65 → 1, 0-32 → 0.
        val expected = mapOf(
            -30 to 3, -40 to 3,
            -41 to 2, -55 to 2, -56 to 2, -70 to 2,
            -71 to 1, -85 to 1,
            -86 to 0, -100 to 0, -101 to 0, -127 to 0
        )

        expected.forEach { (rssi, bars) ->
            assertEquals("rssi $rssi", bars, ChatPeerList.signalBars(rssi))
        }
        assertNull(ChatPeerList.signalBars(null))
    }

    private fun dm(sender: String, at: Long = 1_700_000_000_000L) = BitchatMessage(
        sender = sender,
        content = "hi",
        timestamp = Date(at),
        isPrivate = true,
        senderPeerID = ALICE
    )

    /** One of our favourites as upstream's favourites store records it. */
    private fun favorite(
        noiseKeyHex: String,
        nickname: String,
        theyFavoritedUs: Boolean = false,
        nostrPubkeyHex: String? = null
    ) = ChatFavorites.Favorite(
        noiseKeyHex = noiseKeyHex,
        nostrPubkeyHex = nostrPubkeyHex,
        nickname = nickname,
        theyFavoritedUs = theyFavoritedUs,
        conversationID = "contact_" + noiseKeyHex.reversed()
    )

    private companion object {
        const val ME = "a1b2c3d4e5f60718"
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        const val CAROL = "3333333333333333"
        val CONTACT = "contact_" + "b".repeat(64)
        val FP_ALICE = "a".repeat(64)
        val FP_BOB = "b".repeat(64)
        val FP_CAROL = "c".repeat(64)
        val NOISE_DORA = "d".repeat(63) + "1"
        val NOISE_ERIN = "e".repeat(63) + "2"
        val NOISE_FRED = "f".repeat(63) + "3"
        val CONTACT_DORA = "contact_" + NOISE_DORA.reversed()
        val NOSTR_ERIN = "9".repeat(64)
    }
}
