package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.DeliveryStatus
import com.bitchat.android.ui.CommandSuggestion
import com.bitchat.android.ui.isFromSelf

/**
 * Who "we" are when deciding which messages are our own, as the upstream chat UI decides it:
 * our mesh peer ID and the nickname currently set in [com.bitchat.android.ui.ChatViewModel].
 */
data class ChatSelf(val peerID: String, val nickname: String)

/**
 * Pure chat state → MethodChannel/EventChannel value conversion for the Flutter chat (#49).
 *
 * Every value is a `StandardMessageCodec` type: String, Boolean, Int, Long (epoch millis), null,
 * List and String-keyed Map. The Dart side (`flutter_ui/lib/models/chat_message.dart`,
 * `chat_peer.dart`, `chat_suggestions.dart`) mirrors these keys; change both together.
 */
object ChatSerialization {

    /** Snapshot of the public mesh timeline (`ChatViewModel.messages`). */
    const val EVENT_PUBLIC_MESSAGES = "chat_public_messages"

    /** Snapshot of our own mesh nickname (`ChatViewModel.nickname`). */
    const val EVENT_NICKNAME = "chat_nickname"

    /** Snapshot of the mesh peer list and online count (see [ChatPeerList]). */
    const val EVENT_PEERS = "chat_peers"

    /** Snapshot of the composer's `/` command and `@` mention popups (`ChatViewModel` suggestions). */
    const val EVENT_SUGGESTIONS = "chat_suggestions"

    /** Snapshot of the private chat the native core has in focus (`ChatViewModel.selectedPrivateChatPeer`). */
    const val EVENT_SELECTED_PRIVATE_PEER = "chat_selected_private_peer"

    /** Snapshot of every private conversation upstream holds (`ChatViewModel.privateChats`). */
    const val EVENT_PRIVATE_CHATS = "chat_private_chats"

    /** Snapshot of upstream's unread private messages (see [ChatUnread]). */
    const val EVENT_UNREAD = "chat_unread"

    /** Snapshot of the tapped notification Dart has yet to act on (see [PendingChatNavigation]). */
    const val EVENT_PENDING_NAVIGATION = "chat_pending_navigation"

    // MessageHandler.handleHealthReport() turns every Health Report into a public chat line with
    // exactly this sender and content prefix. The mesh layer is out of bounds for #49, so the
    // markers are mirrored here; HealthReportChatTimelineTest breaks if the producer drifts.
    private const val HEALTH_REPORT_SENDER = "匿名回報"
    private const val HEALTH_REPORT_PREFIX = "[HEALTH REPORT]"

    // Upstream marks its own notices (command output, debug lines) with this sender; its UI
    // checks the same literal (MessageComponents, ChatUIUtils, MessageGrouping).
    private const val SYSTEM_SENDER = "system"

    /**
     * One message. `deliveryStatus` is null when upstream has none (every received public
     * message); `mentions` is always a list, empty when there are none. `isFromSelf`, `isSystem`,
     * `mentionsMe` and `mentionSpans` apply the upstream UI's rules (see [ChatMentions]) so Dart
     * does not re-derive them. `mentionSpans` are `{start, end, isMe}` UTF-16 ranges of the
     * `@name` tokens in `content`, in order; `mentions` stays the raw upstream field.
     */
    fun message(message: BitchatMessage, self: ChatSelf): Map<String, Any?> = mapOf(
        "id" to message.id,
        "sender" to message.sender,
        "senderPeerID" to message.senderPeerID,
        "content" to message.content,
        "timestamp" to message.timestamp.time,
        "isPrivate" to message.isPrivate,
        "mentions" to (message.mentions ?: emptyList()),
        "isRelay" to message.isRelay,
        "deliveryStatus" to deliveryStatus(message.deliveryStatus),
        "isFromSelf" to message.isFromSelf(self.nickname, self.peerID),
        "isSystem" to isSystemLine(message),
        "mentionsMe" to ChatMentions.mentionsMe(message, self),
        "mentionSpans" to ChatMentions.spans(message, self).map(::mentionSpan)
    )

    fun mentionSpan(span: ChatMentions.Span): Map<String, Any?> = mapOf(
        "start" to span.start,
        "end" to span.end,
        "isMe" to span.isMe
    )

    /** Flattens the sealed [DeliveryStatus] into `kind` plus that subtype's fields; null stays null. */
    fun deliveryStatus(status: DeliveryStatus?): Map<String, Any?>? = when (status) {
        null -> null
        is DeliveryStatus.Sending -> mapOf("kind" to "sending")
        is DeliveryStatus.Sent -> mapOf("kind" to "sent")
        is DeliveryStatus.Delivered -> mapOf("kind" to "delivered", "to" to status.to, "at" to status.at.time)
        is DeliveryStatus.Read -> mapOf("kind" to "read", "by" to status.by, "at" to status.at.time)
        is DeliveryStatus.Failed -> mapOf("kind" to "failed", "reason" to status.reason)
        is DeliveryStatus.PartiallyDelivered ->
            mapOf("kind" to "partiallyDelivered", "reached" to status.reached, "total" to status.total)
    }

    /**
     * `{type: "chat_public_messages", messages: [message, ...]}` in timeline order.
     *
     * Health Report lines are left out (#51). The health screen already shows every report,
     * decoded from the raw `packet` event and updated per Reporter. In the timeline the line would
     * be stale — upstream de-duplicates public messages by id and the id is the reporter handle, so
     * only a Reporter's first Status ever shows — and it would sit next to the sender's peer ID,
     * which the anonymous Broadcast Tier deliberately avoids (ADR-0003). It is also only a text
     * line: any peer nicknamed "匿名回報" can type one, so it cannot be trusted as a system notice.
     */
    fun publicMessagesEvent(messages: List<BitchatMessage>, self: ChatSelf): Map<String, Any?> = mapOf(
        "type" to EVENT_PUBLIC_MESSAGES,
        "messages" to messages.filterNot(::isHealthReportLine).map { message(it, self) }
    )

    /**
     * `{type: "chat_nickname", nickname}`: the mesh nickname exactly as upstream holds it — not
     * trimmed, possibly blank (upstream allows that; announces then fall back to the peer ID).
     * This is the name every device in range sees in our ANNOUNCE, never the account's real name.
     */
    fun nicknameEvent(nickname: String): Map<String, Any?> = mapOf(
        "type" to EVENT_NICKNAME,
        "nickname" to nickname
    )

    /**
     * One peer-list row. Every key is always present; `nickname`, `rssi` and `signalBars` may be
     * null. `connection` is a [ChatPeerList.Connection.wire] name; `unreadCount` is 0 when nothing
     * from the peer is unread. Dart mirrors these keys in `flutter_ui/lib/models/chat_peer.dart`;
     * later fields (favourites) are added here and there together.
     */
    fun peer(row: ChatPeerList.Row): Map<String, Any?> = mapOf(
        "peerID" to row.peerID,
        "nickname" to row.nickname,
        "displayName" to row.displayName,
        "displaySuffix" to row.displaySuffix,
        "rssi" to row.rssi,
        "signalBars" to row.signalBars,
        "connection" to row.connection.wire,
        "unreadCount" to row.unreadCount
    )

    /**
     * `{type: "chat_peers", onlineCount, peers: [peer, ...]}` — the native header count and list
     * rows, built from one reading of [inputs] so the two always agree. Rows are in display order.
     * Peer IDs and nicknames are what every device in range already sees in ANNOUNCE packets.
     */
    fun peersEvent(inputs: ChatPeerList.Inputs, isDirectFallback: (String) -> Boolean): Map<String, Any?> = mapOf(
        "type" to EVENT_PEERS,
        "onlineCount" to ChatPeerList.onlineCount(inputs),
        "peers" to ChatPeerList.rows(inputs, isDirectFallback).map(::peer)
    )

    /**
     * One `/` command suggestion, field for field as upstream's [CommandSuggestion]. Dart hands
     * back only `command` to select it (`chat_selectCommandSuggestion`); the bridge looks the
     * upstream object up again rather than rebuilding it.
     */
    fun commandSuggestion(suggestion: CommandSuggestion): Map<String, Any?> = mapOf(
        "command" to suggestion.command,
        "aliases" to suggestion.aliases,
        "syntax" to suggestion.syntax,
        "description" to suggestion.description
    )

    /**
     * `{type: "chat_suggestions", showCommands, commands: [commandSuggestion, ...], showMentions,
     * mentions: [nickname, ...]}` — `ChatViewModel`'s four suggestion flows as they are. Lists are
     * in upstream order (commands sorted, nicknames filtered and sorted by `CommandProcessor`); the
     * native composer shows a popup when its flag is set and its list is not empty.
     */
    fun suggestionsEvent(
        showCommands: Boolean,
        commands: List<CommandSuggestion>,
        showMentions: Boolean,
        mentions: List<String>
    ): Map<String, Any?> = mapOf(
        "type" to EVENT_SUGGESTIONS,
        "showCommands" to showCommands,
        "commands" to commands.map(::commandSuggestion),
        "showMentions" to showMentions,
        "mentions" to mentions
    )

    /**
     * `{type: "chat_selected_private_peer", peerID, conversationID, displayName, draft}` — the
     * private chat upstream routes the composer's text to (see [ChatPrivateChat.Focus]). With no
     * private chat in focus every field but `type` is null: the composer then posts to the public
     * timeline. Dart shows its private chat screen exactly while `peerID` is set. The same map
     * answers `chat_startPrivateChat` and `chat_endPrivateChat`.
     */
    fun selectedPrivatePeerEvent(focus: ChatPrivateChat.Focus?): Map<String, Any?> = mapOf(
        "type" to EVENT_SELECTED_PRIVATE_PEER,
        "peerID" to focus?.peerID,
        "conversationID" to focus?.conversationID,
        "displayName" to focus?.displayName,
        "draft" to focus?.draft
    )

    /**
     * `{type: "chat_private_chats", chats: {conversationID: [message, ...]}}` — upstream's private
     * conversations under upstream's keys, each in upstream's order. A conversation not open holds
     * only its latest message (upstream keeps just a summary row in memory); opening it with
     * `chat_startPrivateChat` loads its stored history, which then arrives in a later snapshot.
     */
    fun privateChatsEvent(chats: Map<String, List<BitchatMessage>>, self: ChatSelf): Map<String, Any?> = mapOf(
        "type" to EVENT_PRIVATE_CHATS,
        "chats" to chats.mapValues { (_, messages) -> messages.map { message(it, self) } }
    )

    /**
     * `{type: "chat_unread", hasUnread, conversations: {conversationID: unreadCount}}` — whether
     * upstream marks any private conversation unread (the native header's envelope,
     * `unreadPrivateMessages`), and the badge of every conversation that has one, under upstream's
     * key (`ChatViewModel.conversations`). A connected peer's badge also rides on its `chat_peers`
     * row. See [ChatUnread].
     */
    fun unreadEvent(
        unreadConversationIDs: Set<String>,
        conversations: List<ChatUnread.Conversation>
    ): Map<String, Any?> = mapOf(
        "type" to EVENT_UNREAD,
        "hasUnread" to unreadConversationIDs.isNotEmpty(),
        "conversations" to conversations.associate { it.conversationID to it.unreadCount }
    )

    /**
     * Where a tapped notification asks to go: `{target: "privateChat", peerID, senderNickname}`
     * (`senderNickname` may be null) or `{target: "publicChat"}`; null for nowhere. Answers
     * `chat_takePendingNavigation`. Dart mirrors it in `flutter_ui/lib/models/chat_navigation.dart`.
     */
    fun navigation(navigation: ChatNavigation?): Map<String, Any?>? = when (navigation) {
        null -> null
        is ChatNavigation.PrivateChat -> mapOf(
            "target" to "privateChat",
            "peerID" to navigation.peerID,
            "senderNickname" to navigation.senderNickname
        )
        ChatNavigation.PublicChat -> mapOf("target" to "publicChat")
    }

    /**
     * `{type: "chat_pending_navigation", navigation}` — the tapped notification waiting for Dart
     * ([navigation] map, null when none). It only tells Dart there is one: Dart navigates on what
     * `chat_takePendingNavigation` answers, so each tap is acted on once.
     */
    fun pendingNavigationEvent(navigation: ChatNavigation?): Map<String, Any?> = mapOf(
        "type" to EVENT_PENDING_NAVIGATION,
        "navigation" to navigation(navigation)
    )

    /** True for upstream's own notices (command output, debug lines), drawn as system lines. */
    fun isSystemLine(message: BitchatMessage): Boolean = message.sender == SYSTEM_SENDER

    /** True for the chat line MessageHandler.handleHealthReport() makes out of a Health Report. */
    fun isHealthReportLine(message: BitchatMessage): Boolean =
        !message.isPrivate &&
            message.sender == HEALTH_REPORT_SENDER &&
            message.content.startsWith(HEALTH_REPORT_PREFIX)
}
