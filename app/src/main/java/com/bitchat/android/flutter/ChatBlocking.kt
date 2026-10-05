package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.ui.ConversationSummary
import com.bitchat.android.ui.isFromSelf

/**
 * Blocked peers in the Flutter chat (#58): what `/block` hides, as pure functions over upstream's
 * own decision (`PrivateChatManager.isPeerBlocked`, read through [ChatRecords]); fixed by
 * `ChatBlockingTest`.
 *
 * Blocking itself is upstream's: `/block name`, `/unblock name` and the bare `/block` listing run in
 * `CommandProcessor` (through `chat_sendMessage`), which saves the fingerprint in `DataManager`
 * (`bitchat_prefs`, so it survives a restart) and posts its system line to the timeline. Upstream
 * also refuses to open or send to a blocked peer's private chat itself.
 *
 * Upstream's rule for what a blocked peer may still show is `MeshDelegateHandler.didReceiveMessage`:
 * an incoming message whose `senderPeerID` is blocked is dropped before it reaches the UI. That
 * check no longer hides anything in this version of upstream — the transport already admitted the
 * message to `AppStateStore` (`IncomingMessageAdmission`), which is what the timelines show, so the
 * check only holds back the notification, vibration and unread tracking. The projection applies the
 * same rule to what it pushes instead:
 * - public timeline: an incoming message whose `senderPeerID` is blocked.
 * - private chats: the incoming messages of a conversation whose key is blocked. Upstream files
 *   each incoming private message under its sender's canonical conversation ID, so the key names
 *   the peer every incoming message in it came from — and it is one lookup per conversation.
 * - unread: a blocked peer's conversation counts as nothing unread (all its unread messages are
 *   hidden), so neither the envelope nor a badge points at messages that are not shown.
 * - conversation list (#73): a blocked peer's conversation is not listed at all — its preview, name
 *   and badge come from the messages that are hidden. The peer is then shown among the people like
 *   any peer without a conversation (upstream lists blocked peers there too), and opening its chat
 *   is refused by upstream as before.
 *
 * Because the projection filters, it hides what came before the block too, and `/unblock` brings
 * everything back — received while blocked included: upstream still holds it all.
 */
object ChatBlocking {

    /** [isBlocked], asked at most once per ID; for one snapshot, as the block list may change. */
    fun memo(isBlocked: (String) -> Boolean): (String) -> Boolean {
        val answers = HashMap<String, Boolean>()
        return { id -> answers.getOrPut(id) { isBlocked(id) } }
    }

    /** `MeshDelegateHandler.didReceiveMessage`'s check: incoming, from a blocked sender. Never our own. */
    fun isHidden(message: BitchatMessage, self: ChatSelf, isBlocked: (String) -> Boolean): Boolean {
        val sender = message.senderPeerID ?: return false
        return !message.isFromSelf(self.nickname, self.peerID) && isBlocked(sender)
    }

    fun visiblePublicMessages(
        messages: List<BitchatMessage>,
        self: ChatSelf,
        isBlocked: (String) -> Boolean
    ): List<BitchatMessage> = messages.filterNot { isHidden(it, self, isBlocked) }

    fun visiblePrivateChats(
        chats: Map<String, List<BitchatMessage>>,
        self: ChatSelf,
        isBlocked: (String) -> Boolean
    ): Map<String, List<BitchatMessage>> = chats.mapValues { (conversationID, messages) ->
        if (isBlocked(conversationID)) {
            messages.filter { it.isFromSelf(self.nickname, self.peerID) }
        } else {
            messages
        }
    }

    /** `ChatViewModel.unreadPrivateMessages` without blocked peers' conversations. */
    fun visibleUnread(unreadConversationIDs: Set<String>, isBlocked: (String) -> Boolean): Set<String> =
        unreadConversationIDs.filterNotTo(LinkedHashSet()) { isBlocked(it) }

    /** Upstream's conversation list (`ChatViewModel.conversations`) without blocked peers' conversations. */
    internal fun visibleSummaries(
        conversations: List<ConversationSummary>,
        isBlocked: (String) -> Boolean
    ): List<ConversationSummary> = conversations.filterNot { isBlocked(it.conversationID) }

    /** Unread conversation badges without blocked peers' conversations. */
    fun visibleConversations(
        conversations: List<ChatUnread.Conversation>,
        isBlocked: (String) -> Boolean
    ): List<ChatUnread.Conversation> = conversations.filterNot { isBlocked(it.conversationID) }
}
