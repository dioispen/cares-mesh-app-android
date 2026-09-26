package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.DeliveryStatus
import com.bitchat.android.ui.isFromSelf

/**
 * Who "we" are when deciding which messages are our own, as the upstream chat UI decides it:
 * our mesh peer ID and the nickname currently set in [com.bitchat.android.ui.ChatViewModel].
 */
data class ChatSelf(val peerID: String, val nickname: String)

/**
 * Pure `BitchatMessage` → MethodChannel/EventChannel value conversion for the Flutter chat (#49).
 *
 * Every value is a `StandardMessageCodec` type: String, Boolean, Int, Long (epoch millis), null,
 * List and String-keyed Map. The Dart side (`flutter_ui/lib/models/chat_message.dart`) mirrors
 * these keys; change both together.
 */
object ChatSerialization {

    /** Snapshot of the public mesh timeline (`ChatViewModel.messages`). */
    const val EVENT_PUBLIC_MESSAGES = "chat_public_messages"

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
     * message); `mentions` is always a list, empty when there are none. `isFromSelf` and
     * `isSystem` apply the upstream UI's rules so Dart does not re-derive them.
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
        "isSystem" to (message.sender == SYSTEM_SENDER)
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

    /** True for the chat line MessageHandler.handleHealthReport() makes out of a Health Report. */
    fun isHealthReportLine(message: BitchatMessage): Boolean =
        !message.isPrivate &&
            message.sender == HEALTH_REPORT_SENDER &&
            message.content.startsWith(HEALTH_REPORT_PREFIX)
}
