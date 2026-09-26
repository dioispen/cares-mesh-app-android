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
     * null. `connection` is a [ChatPeerList.Connection.wire] name. Dart mirrors these keys in
     * `flutter_ui/lib/models/chat_peer.dart`; later fields (private chat, unread, favourites) are
     * added here and there together.
     */
    fun peer(row: ChatPeerList.Row): Map<String, Any?> = mapOf(
        "peerID" to row.peerID,
        "nickname" to row.nickname,
        "displayName" to row.displayName,
        "displaySuffix" to row.displaySuffix,
        "rssi" to row.rssi,
        "signalBars" to row.signalBars,
        "connection" to row.connection.wire
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

    /** True for upstream's own notices (command output, debug lines), drawn as system lines. */
    fun isSystemLine(message: BitchatMessage): Boolean = message.sender == SYSTEM_SENDER

    /** True for the chat line MessageHandler.handleHealthReport() makes out of a Health Report. */
    fun isHealthReportLine(message: BitchatMessage): Boolean =
        !message.isPrivate &&
            message.sender == HEALTH_REPORT_SENDER &&
            message.content.startsWith(HEALTH_REPORT_PREFIX)
}
