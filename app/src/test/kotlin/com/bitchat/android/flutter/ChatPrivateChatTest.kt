package com.bitchat.android.flutter

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Fixes the private chat title rule [ChatPrivateChat.displayName] reproduces from upstream's
 * private chat screen (`ui/MeshPeerListSheet.kt` `PrivateChatSheet`, `displayName`), so the
 * Flutter private chat is named as the native one is — including after the peer went offline.
 */
class ChatPrivateChatTest {

    private fun contact(
        conversationID: String = CONTACT,
        meshPeerID: String? = null,
        displayName: String? = null,
        favoriteNickname: String? = null
    ) = ChatPrivateChat.Contact(conversationID, meshPeerID, displayName, favoriteNickname)

    private fun name(
        peerID: String,
        contact: ChatPrivateChat.Contact,
        peerNicknames: Map<String, String> = emptyMap(),
        fingerprintName: String = "fp-name"
    ) = ChatPrivateChat.displayName(peerID, contact, peerNicknames) { fingerprintName }

    @Test
    fun `the nickname announced under the selected ID comes first`() {
        val title = name(
            ALICE,
            contact(conversationID = ALICE, meshPeerID = ALICE, displayName = "old-alice"),
            peerNicknames = mapOf(ALICE to "alice")
        )

        assertEquals("alice", title)
    }

    @Test
    fun `a contact conversation is named by the peer it is live under`() {
        val title = name(
            CONTACT,
            contact(meshPeerID = ALICE, displayName = "old-alice"),
            peerNicknames = mapOf(ALICE to "alice")
        )

        assertEquals("alice", title)
    }

    @Test
    fun `an offline contact keeps the name upstream's records give it`() {
        // Upstream's resolution falls back to the favourite record, then the nickname cached for
        // the contact's fingerprint; either way it arrives as the contact's display name.
        assertEquals("alice", name(CONTACT, contact(displayName = "alice", favoriteNickname = "fav-alice")))
    }

    @Test
    fun `the favourite record's nickname is next`() {
        assertEquals("fav-alice", name(CONTACT, contact(favoriteNickname = "fav-alice")))
    }

    @Test
    fun `a blank or Unknown favourite nickname is skipped`() {
        listOf("", "  ", "Unknown", "unknown").forEach { nickname ->
            assertEquals("'$nickname'", "fp-name", name(CONTACT, contact(favoriteNickname = nickname)))
        }
    }

    @Test
    fun `with nothing else known the fingerprint lookup names the chat`() {
        assertEquals("fp-name", name(ALICE, contact(conversationID = ALICE)))
    }

    @Test
    fun `the fingerprint lookup is only asked when nothing else names the chat`() {
        var asked = 0

        ChatPrivateChat.displayName(ALICE, contact(conversationID = ALICE), mapOf(ALICE to "alice")) {
            asked++
            "fp-name"
        }

        assertEquals(0, asked)
    }

    @Test
    fun `a nickname announced under another peer does not name this chat`() {
        val title = name(ALICE, contact(conversationID = ALICE), peerNicknames = mapOf(BOB to "bob"))

        assertEquals("fp-name", title)
    }

    private companion object {
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        val CONTACT = "contact_" + "a".repeat(64)
    }
}
