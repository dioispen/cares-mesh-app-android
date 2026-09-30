package com.bitchat.android.flutter

import com.bitchat.android.ui.ConversationSummary

/**
 * Unread private messages as the native chat shows them, for the Flutter chat (#56).
 *
 * Upstream keeps two views of them; the bridge only reads both, and never clears anything —
 * opening a conversation does (`ChatViewModel.startPrivateChat` reads its messages and drops its
 * unread mark), exactly as in the native app.
 * - `ChatViewModel.unreadPrivateMessages`, the conversation IDs marked unread: the native header
 *   shows its "unread private messages" envelope while it is not empty (`ChatHeader.kt`
 *   `MainHeader`); tapping it runs `ChatViewModel.openLatestUnreadPrivateChat`.
 * - `ChatViewModel.conversations`, one [ConversationSummary] per conversation: its `unreadCount` is
 *   the number badge on the conversation's row in the native sheet (`MeshPeerListSheet.kt`
 *   `ConversationRow` → `UnreadBadge`) — the stored unread count, or its unread incoming messages.
 *   While the peer is on the mesh the summary names it (`connectedPeerID`), and the native sheet
 *   lists the conversation among its online conversations rather than as a People row.
 */
object ChatUnread {

    /** A conversation with unread messages: upstream's key, its peer while online, its badge. */
    data class Conversation(
        val conversationID: String,
        /** The connected mesh peer upstream links the conversation to; null while offline. */
        val connectedPeerID: String?,
        /** Always > 0. */
        val unreadCount: Int
    )

    /** The conversations upstream shows a badge for (`unreadCount > 0`), in upstream's order. */
    internal fun conversations(summaries: List<ConversationSummary>): List<Conversation> =
        summaries
            .filter { it.unreadCount > 0 }
            .map { Conversation(it.conversationID, it.connectedPeerID, it.unreadCount) }

    /**
     * The badge for connected [peerID]: the count of the online conversation upstream links to it,
     * 0 when it has none. (Upstream folds a peer's aliases into one canonical conversation; should
     * two ever name the same peer, their counts add up.)
     */
    fun countFor(peerID: String, conversations: List<Conversation>): Int =
        conversations.filter { it.connectedPeerID == peerID }.sumOf { it.unreadCount }
}
