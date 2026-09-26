package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/**
 * The native chat's mention highlighting (ui/ChatUIUtils.kt `appendIOSFormattedContent`), as the
 * Flutter chat receives it: token ranges plus whether a message someone else sent mentions us.
 */
class ChatMentionsTest {

    private val me = ChatSelf(peerID = "a1b2c3d4e5f60718", nickname = "me")

    private fun message(
        content: String,
        sender: String = "alice",
        senderPeerID: String? = "1122334455667788"
    ) = BitchatMessage(
        sender = sender,
        content = content,
        timestamp = Date(1_700_000_000_000L),
        senderPeerID = senderPeerID
    )

    private fun spans(content: String, nickname: String = me.nickname) =
        ChatMentions.spans(content, nickname).map { Triple(content.substring(it.start, it.end), it.start, it.isMe) }

    // --- spans ---------------------------------------------------------------------------------

    @Test
    fun `every mention token becomes a span, flagged when it names us`() {
        assertEquals(
            listOf(Triple("@bob", 3, false), Triple("@me", 13, true)),
            spans("hi @bob, and @me!")
        )
    }

    @Test
    fun `text without mentions has no spans`() {
        assertEquals(emptyList<Any>(), spans("no mentions here, just an email-less line"))
    }

    @Test
    fun `the hash suffix is part of the token and does not stop it naming us`() {
        assertEquals(listOf(Triple("@me#1a2b", 0, true)), spans("@me#1a2b look"))
    }

    @Test
    fun `a longer name that starts with ours is someone else`() {
        assertEquals(listOf(Triple("@meow", 0, false)), spans("@meow"))
    }

    @Test
    fun `the comparison is case sensitive, as the native chip is`() {
        assertEquals(listOf(Triple("@Me", 0, false)), spans("@Me there"))
    }

    @Test
    fun `span offsets are UTF-16 indices, the unit Dart strings use`() {
        val content = "🫂 @小明 hi"

        val span = ChatMentions.spans(content, "小明").single()

        assertEquals(3, span.start)
        assertEquals(6, span.end)
        assertTrue(span.isMe)
    }

    @Test
    fun `a nickname outside the token grammar never matches`() {
        // Upstream's token is @[letters digits _]; a spaced nickname cannot be written as one.
        assertEquals(listOf(Triple("@bob", 0, false)), spans("@bob smith", nickname = "bob smith"))
    }

    // --- mentionsMe ----------------------------------------------------------------------------

    @Test
    fun `someone else's message that mentions us mentions me`() {
        assertTrue(ChatMentions.mentionsMe(message("hey @me, you there?"), me))
    }

    @Test
    fun `a message mentioning only others does not`() {
        assertFalse(ChatMentions.mentionsMe(message("hey @bob"), me))
        assertFalse(ChatMentions.mentionsMe(message("hey everyone"), me))
    }

    @Test
    fun `our own message never counts as mentioning us`() {
        assertFalse(ChatMentions.mentionsMe(message("note to @me", sender = "me"), me))
        assertFalse(ChatMentions.mentionsMe(message("note to @me", sender = "renamed", senderPeerID = me.peerID), me))
    }

    @Test
    fun `a system line never mentions us`() {
        assertFalse(ChatMentions.mentionsMe(message("online users: @me", sender = "system", senderPeerID = null), me))
    }
}
