package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
        privateChats: Map<String, List<BitchatMessage>> = emptyMap()
    ) = ChatPeerList.Inputs(
        myPeerID = ME,
        connectedPeers = connectedPeers,
        peerNicknames = peerNicknames,
        peerRSSI = peerRSSI,
        peerDirect = peerDirect,
        wifiAwarePeerIDs = wifiAwarePeerIDs,
        privateChats = privateChats
    )

    private fun rows(inputs: ChatPeerList.Inputs, isDirectFallback: (String) -> Boolean = { false }) =
        ChatPeerList.rows(inputs, isDirectFallback)

    private fun row(inputs: ChatPeerList.Inputs, isDirectFallback: (String) -> Boolean = { false }) =
        rows(inputs, isDirectFallback).single()

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
            listOf("wifiAware", "bluetooth", "routed"),
            ChatPeerList.Connection.values().map { it.wire }
        )
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

    private fun dm(sender: String) = BitchatMessage(
        sender = sender,
        content = "hi",
        timestamp = Date(1_700_000_000_000L),
        isPrivate = true,
        senderPeerID = ALICE
    )

    private companion object {
        const val ME = "a1b2c3d4e5f60718"
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        const val CAROL = "3333333333333333"
    }
}
