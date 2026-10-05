package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessageType
import com.bitchat.android.ui.ConversationSummary
import com.bitchat.android.ui.DirectMessageTransport
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Fixes which upstream unread counts the Flutter chat shows (#56): the badges of the native
 * sheet's conversation rows (`ChatViewModel.conversations`), unchanged.
 */
class ChatUnreadTest {

    @Test
    fun `only the conversations upstream badges are kept, in upstream order`() {
        val conversations = ChatUnread.conversations(
            listOf(
                summary(CONTACT_A, unreadCount = 3, connectedPeerID = ALICE),
                summary(CONTACT_B, unreadCount = 0, connectedPeerID = BOB),
                summary(OFFLINE, unreadCount = 1, connectedPeerID = null)
            )
        )

        assertEquals(
            listOf(
                ChatUnread.Conversation(CONTACT_A, ALICE, 3),
                ChatUnread.Conversation(OFFLINE, null, 1)
            ),
            conversations
        )
    }

    @Test
    fun `nothing unread is an empty list`() {
        assertEquals(emptyList<ChatUnread.Conversation>(), ChatUnread.conversations(emptyList()))
        assertEquals(
            emptyList<ChatUnread.Conversation>(),
            ChatUnread.conversations(listOf(summary(CONTACT_A, unreadCount = 0, connectedPeerID = ALICE)))
        )
    }

    @Test
    fun `a connected peer's count is the badge of the conversation upstream puts it in`() {
        val conversations = listOf(
            ChatUnread.Conversation(CONTACT_A, ALICE, 3),
            ChatUnread.Conversation(CONTACT_B, BOB, 1),
            ChatUnread.Conversation(OFFLINE, null, 5)
        )

        assertEquals(3, ChatUnread.countFor(ALICE, conversations))
        assertEquals(1, ChatUnread.countFor(BOB, conversations))
        assertEquals("no conversation of its own", 0, ChatUnread.countFor(CAROL, conversations))
    }

    @Test
    fun `a peer upstream links to several conversations gets their sum`() {
        // Upstream folds a peer's aliases into one canonical conversation, so this is a fallback.
        val conversations = listOf(
            ChatUnread.Conversation(CONTACT_A, ALICE, 2),
            ChatUnread.Conversation(ALICE, ALICE, 1)
        )

        assertEquals(3, ChatUnread.countFor(ALICE, conversations))
    }

    private fun summary(conversationID: String, unreadCount: Int, connectedPeerID: String?) = ConversationSummary(
        conversationID = conversationID,
        displayName = conversationID.take(8),
        unreadCount = unreadCount,
        latestMessageAt = 1_700_000_000_000L,
        latestActivityOrder = 1L,
        latestMessageType = BitchatMessageType.Message,
        latestMessagePreview = "hi",
        transport = DirectMessageTransport.MESH,
        nostrPubkey = null,
        identityAliases = setOf(conversationID.lowercase()),
        isConnected = connectedPeerID != null,
        connectedPeerID = connectedPeerID
    )

    private companion object {
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        const val CAROL = "3333333333333333"
        val CONTACT_A = "contact_" + "a".repeat(64)
        val CONTACT_B = "contact_" + "b".repeat(64)
        val OFFLINE = "contact_" + "c".repeat(64)
    }
}
