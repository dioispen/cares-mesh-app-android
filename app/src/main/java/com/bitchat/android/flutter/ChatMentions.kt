package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.ui.MENTION_TOKEN_REGEX
import com.bitchat.android.ui.isFromSelf
import com.bitchat.android.ui.splitSuffix

/**
 * How the native chat highlights `@mentions` in a message, for the Flutter chat (#54).
 *
 * Upstream does this inside its Compose text builder (`ui/ChatUIUtils.kt`
 * `appendIOSFormattedContent`), which the bridge cannot call, so the rule is reproduced here with
 * upstream's own pieces — the shared token grammar [MENTION_TOKEN_REGEX] and [splitSuffix] — and
 * fixed by `ChatMentionsTest`. Dart only renders the result and parses no mentions itself.
 *
 * Upstream's rule: every `@name` or `@name#abcd` token in the content is a mention chip; the chip
 * is "to me" when the token's name, `#abcd` suffix removed, equals our current nickname exactly
 * (case-sensitive). System lines are drawn as plain text (`formatSystemMessage`), so they carry no
 * chips.
 *
 * Not mirrored: upstream's mention *notification* check (`MeshDelegateHandler.checkForMeshMention`)
 * matches `@name` case-insensitively. It only decides whether to post a notification for a
 * received message, which upstream still does by itself (#57); the Flutter transcript highlights
 * what the native transcript highlights.
 */
object ChatMentions {

    /** One mention token: `content.substring(start, end)` in UTF-16 units, as Dart indexes too. */
    data class Span(val start: Int, val end: Int, val isMe: Boolean)

    /** Every mention token of [content] in order, flagged when it names [nickname]. */
    fun spans(content: String, nickname: String): List<Span> =
        MENTION_TOKEN_REGEX.findAll(content).map { match ->
            Span(
                start = match.range.first,
                end = match.range.last + 1,
                isMe = splitSuffix(match.groupValues[1]).first == nickname
            )
        }.toList()

    /** Spans as upstream draws them for [message]: none for a system line. */
    fun spans(message: BitchatMessage, self: ChatSelf): List<Span> =
        if (ChatSerialization.isSystemLine(message)) emptyList() else spans(message.content, self.nickname)

    /**
     * Whether someone else's message mentions us: it holds a mention chip upstream draws as ours.
     * Our own messages never count — we do not need telling that we wrote our own nickname.
     */
    fun mentionsMe(message: BitchatMessage, self: ChatSelf): Boolean =
        !message.isFromSelf(self.nickname, self.peerID) && spans(message, self).any { it.isMe }
}
