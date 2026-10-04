package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.BitchatMessageType
import com.bitchat.android.ui.ConversationSummary
import com.bitchat.android.ui.DirectMessageTransport
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Date

/**
 * Fixes how the Flutter chat hides blocked peers ([ChatBlocking]): with upstream's own decision
 * (`PrivateChatManager.isPeerBlocked`), applied the way `MeshDelegateHandler.didReceiveMessage`
 * applies it — to the incoming message's `senderPeerID`.
 */
class ChatBlockingTest {

    private val me = ChatSelf(peerID = ME, nickname = "me")
    private val blocked = mutableSetOf<String>()
    private val lookups = mutableListOf<String>()
    private val isBlocked: (String) -> Boolean = { id -> lookups += id; id in blocked }

    // --- public timeline --------------------------------------------------------------------

    @Test
    fun `a blocked peer's public messages are hidden, everyone else's stay`() {
        blocked += MALLORY
        val timeline = listOf(
            message("A1", sender = "alice", senderPeerID = ALICE),
            message("M1", sender = "mallory", senderPeerID = MALLORY),
            message("A2", sender = "alice", senderPeerID = ALICE)
        )

        assertEquals(listOf("A1", "A2"), ChatBlocking.visiblePublicMessages(timeline, me, isBlocked).map { it.id })
    }

    @Test
    fun `our own messages and lines without a sender are never hidden`() {
        // Upstream's check only applies to messages that carry a senderPeerID; system lines
        // (command output, "blocked user x") carry none.
        blocked += ME
        val timeline = listOf(
            message("MINE", sender = "me", senderPeerID = ME),
            message("SYS", sender = "system", senderPeerID = null)
        )

        assertEquals(listOf("MINE", "SYS"), ChatBlocking.visiblePublicMessages(timeline, me, isBlocked).map { it.id })
    }

    @Test
    fun `nothing is hidden for a peer upstream no longer blocks`() {
        val timeline = listOf(message("M1", sender = "mallory", senderPeerID = MALLORY))
        blocked += MALLORY
        assertEquals(emptyList<String>(), ChatBlocking.visiblePublicMessages(timeline, me, isBlocked).map { it.id })

        // /unblock: the very same timeline shows the peer again, earlier messages included.
        blocked -= MALLORY
        assertEquals(listOf("M1"), ChatBlocking.visiblePublicMessages(timeline, me, isBlocked).map { it.id })
    }

    @Test
    fun `each sender is looked up once per snapshot`() {
        val memo = ChatBlocking.memo(isBlocked)
        val timeline = List(5) { i -> message("A$i", senderPeerID = ALICE) } +
            List(3) { i -> message("M$i", senderPeerID = MALLORY) }

        ChatBlocking.visiblePublicMessages(timeline, me, memo)

        assertEquals(listOf(ALICE, MALLORY), lookups)
    }

    // --- private chats ------------------------------------------------------------------------

    @Test
    fun `a conversation with a blocked peer keeps only our own messages`() {
        blocked += MALLORY_CONTACT
        val chats = mapOf(
            MALLORY_CONTACT to listOf(
                message("IN", sender = "mallory", senderPeerID = MALLORY, isPrivate = true),
                message("OUT", sender = "me", senderPeerID = ME, isPrivate = true),
                // MessageHandler mirrors "mallory favorited you" into the conversation under its ID.
                message("NOTICE", sender = "system", senderPeerID = MALLORY_CONTACT, isPrivate = true)
            ),
            ALICE_CONTACT to listOf(message("ALICE", sender = "alice", senderPeerID = ALICE, isPrivate = true))
        )

        val visible = ChatBlocking.visiblePrivateChats(chats, me, isBlocked)

        assertEquals(
            mapOf(MALLORY_CONTACT to listOf("OUT"), ALICE_CONTACT to listOf("ALICE")),
            visible.mapValues { (_, messages) -> messages.map { it.id } }
        )
    }

    @Test
    fun `private chats are judged by their conversation key, once each`() {
        // Upstream files every incoming private message under its sender's canonical conversation
        // ID, so the key names the peer every message in it came from.
        val chats = mapOf(
            ALICE_CONTACT to List(4) { i -> message("A$i", senderPeerID = ALICE, isPrivate = true) },
            MALLORY_CONTACT to listOf(message("M", senderPeerID = MALLORY, isPrivate = true))
        )

        ChatBlocking.visiblePrivateChats(chats, me, isBlocked)

        assertEquals(listOf(ALICE_CONTACT, MALLORY_CONTACT), lookups)
    }

    // --- unread -------------------------------------------------------------------------------

    @Test
    fun `a blocked peer's conversation counts as nothing unread`() {
        blocked += MALLORY_CONTACT

        assertEquals(setOf(ALICE_CONTACT), ChatBlocking.visibleUnread(setOf(ALICE_CONTACT, MALLORY_CONTACT), isBlocked))
        assertEquals(
            listOf(ChatUnread.Conversation(ALICE_CONTACT, ALICE, 2)),
            ChatBlocking.visibleConversations(
                listOf(ChatUnread.Conversation(ALICE_CONTACT, ALICE, 2), ChatUnread.Conversation(MALLORY_CONTACT, MALLORY, 5)),
                isBlocked
            )
        )
    }

    // --- conversation list (#73) -------------------------------------------------------------

    @Test
    fun `a blocked peer's conversation is not listed, the others keep upstream's order`() {
        blocked += MALLORY_CONTACT

        val listed = ChatBlocking.visibleSummaries(
            listOf(summary(MALLORY_CONTACT), summary(ALICE_CONTACT), summary(BOB)),
            isBlocked
        )

        assertEquals(listOf(ALICE_CONTACT, BOB), listed.map { it.conversationID })
        assertEquals("one lookup per conversation", listOf(MALLORY_CONTACT, ALICE_CONTACT, BOB), lookups)
    }

    private fun summary(conversationID: String) = ConversationSummary(
        conversationID = conversationID,
        displayName = conversationID.take(8),
        unreadCount = 0,
        latestMessageAt = 1_700_000_000_000L,
        latestActivityOrder = 1L,
        latestMessageType = BitchatMessageType.Message,
        latestMessagePreview = "hi",
        transport = DirectMessageTransport.MESH,
        nostrPubkey = null,
        identityAliases = setOf(conversationID)
    )

    private fun message(
        id: String,
        sender: String = "alice",
        senderPeerID: String? = ALICE,
        isPrivate: Boolean = false
    ) = BitchatMessage(
        id = id,
        sender = sender,
        content = "content of $id",
        timestamp = Date(1_700_000_000_000L),
        isPrivate = isPrivate,
        senderPeerID = senderPeerID
    )

    private companion object {
        const val ME = "a1b2c3d4e5f60718"
        const val ALICE = "1111111111111111"
        const val MALLORY = "6666666666666666"
        const val BOB = "2222222222222222"
        val ALICE_CONTACT = "contact_" + "a".repeat(64)
        val MALLORY_CONTACT = "contact_" + "6".repeat(64)
    }
}
