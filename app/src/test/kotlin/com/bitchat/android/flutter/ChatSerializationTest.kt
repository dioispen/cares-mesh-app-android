package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.DeliveryStatus
import io.flutter.plugin.common.StandardMessageCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class ChatSerializationTest {

    private val me = ChatSelf(peerID = "a1b2c3d4e5f60718", nickname = "me")
    private val sentAt = Date(1_700_000_000_123L)
    private val statusAt = Date(1_700_000_005_000L)

    private fun message(
        id: String = "MSG-1",
        sender: String = "alice",
        senderPeerID: String? = "1122334455667788",
        content: String = "hello mesh",
        isPrivate: Boolean = false,
        mentions: List<String>? = null,
        isRelay: Boolean = false,
        deliveryStatus: DeliveryStatus? = null
    ) = BitchatMessage(
        id = id,
        sender = sender,
        content = content,
        timestamp = sentAt,
        isRelay = isRelay,
        isPrivate = isPrivate,
        senderPeerID = senderPeerID,
        mentions = mentions,
        deliveryStatus = deliveryStatus
    )

    @Test
    fun `public message maps every bridge field`() {
        val map = ChatSerialization.message(message(isRelay = true), me)

        assertEquals(
            mapOf(
                "id" to "MSG-1",
                "sender" to "alice",
                "senderPeerID" to "1122334455667788",
                "content" to "hello mesh",
                "timestamp" to 1_700_000_000_123L,
                "isPrivate" to false,
                "mentions" to emptyList<String>(),
                "isRelay" to true,
                "deliveryStatus" to null,
                "isFromSelf" to false,
                "isSystem" to false
            ),
            map
        )
    }

    @Test
    fun `private message is marked private`() {
        val map = ChatSerialization.message(message(isPrivate = true), me)

        assertEquals(true, map["isPrivate"])
    }

    @Test
    fun `mentions are carried in order`() {
        val map = ChatSerialization.message(message(mentions = listOf("me", "bob")), me)

        assertEquals(listOf("me", "bob"), map["mentions"])
    }

    @Test
    fun `message without mentions carries an empty list`() {
        assertEquals(emptyList<String>(), ChatSerialization.message(message(mentions = null), me)["mentions"])
        assertEquals(emptyList<String>(), ChatSerialization.message(message(mentions = emptyList()), me)["mentions"])
    }

    @Test
    fun `missing sender peer id stays null`() {
        val map = ChatSerialization.message(message(senderPeerID = null), me)

        assertTrue(map.containsKey("senderPeerID"))
        assertNull(map["senderPeerID"])
    }

    @Test
    fun `message without delivery status carries null`() {
        val map = ChatSerialization.message(message(deliveryStatus = null), me)

        assertTrue(map.containsKey("deliveryStatus"))
        assertNull(map["deliveryStatus"])
    }

    @Test
    fun `sending status flattens to its kind`() {
        assertEquals(mapOf("kind" to "sending"), ChatSerialization.deliveryStatus(DeliveryStatus.Sending))
    }

    @Test
    fun `sent status flattens to its kind`() {
        assertEquals(mapOf("kind" to "sent"), ChatSerialization.deliveryStatus(DeliveryStatus.Sent))
    }

    @Test
    fun `delivered status carries recipient and epoch millis`() {
        assertEquals(
            mapOf("kind" to "delivered", "to" to "bob", "at" to 1_700_000_005_000L),
            ChatSerialization.deliveryStatus(DeliveryStatus.Delivered(to = "bob", at = statusAt))
        )
    }

    @Test
    fun `read status carries reader and epoch millis`() {
        assertEquals(
            mapOf("kind" to "read", "by" to "bob", "at" to 1_700_000_005_000L),
            ChatSerialization.deliveryStatus(DeliveryStatus.Read(by = "bob", at = statusAt))
        )
    }

    @Test
    fun `failed status carries its reason`() {
        assertEquals(
            mapOf("kind" to "failed", "reason" to "Message expired before delivery"),
            ChatSerialization.deliveryStatus(DeliveryStatus.Failed("Message expired before delivery"))
        )
    }

    @Test
    fun `partially delivered status carries reached and total`() {
        assertEquals(
            mapOf("kind" to "partiallyDelivered", "reached" to 2, "total" to 5),
            ChatSerialization.deliveryStatus(DeliveryStatus.PartiallyDelivered(reached = 2, total = 5))
        )
    }

    @Test
    fun `delivery status is nested inside the message map`() {
        val map = ChatSerialization.message(
            message(isPrivate = true, deliveryStatus = DeliveryStatus.Read(by = "bob", at = statusAt)),
            me
        )

        assertEquals(mapOf("kind" to "read", "by" to "bob", "at" to 1_700_000_005_000L), map["deliveryStatus"])
    }

    @Test
    fun `own message is recognised by our peer id`() {
        val map = ChatSerialization.message(message(sender = "renamed", senderPeerID = me.peerID), me)

        assertEquals(true, map["isFromSelf"])
    }

    @Test
    fun `own message is recognised by our nickname`() {
        val map = ChatSerialization.message(message(sender = "me", senderPeerID = "ffffffffffffffff"), me)

        assertEquals(true, map["isFromSelf"])
    }

    @Test
    fun `someone else's message is not ours`() {
        assertEquals(false, ChatSerialization.message(message(), me)["isFromSelf"])
    }

    @Test
    fun `upstream system line is flagged as system`() {
        val map = ChatSerialization.message(message(sender = "system", senderPeerID = null), me)

        assertEquals(true, map["isSystem"])
        assertEquals(false, map["isFromSelf"])
    }

    @Test
    fun `every value survives a StandardMessageCodec round trip`() {
        val statuses = listOf(
            null,
            DeliveryStatus.Sending,
            DeliveryStatus.Sent,
            DeliveryStatus.Delivered("bob", statusAt),
            DeliveryStatus.Read("bob", statusAt),
            DeliveryStatus.Failed("nope"),
            DeliveryStatus.PartiallyDelivered(1, 3)
        )
        val event = ChatSerialization.publicMessagesEvent(
            statuses.mapIndexed { i, status ->
                message(id = "M$i", mentions = listOf("me"), deliveryStatus = status)
            },
            me
        )

        val codec = StandardMessageCodec.INSTANCE
        val encoded = codec.encodeMessage(event)!!.also { it.rewind() }

        assertEquals(event, codec.decodeMessage(encoded))
    }

    @Test
    fun `public messages event carries the timeline in order`() {
        val event = ChatSerialization.publicMessagesEvent(
            listOf(message(id = "A", content = "first"), message(id = "B", content = "second")),
            me
        )

        assertEquals("chat_public_messages", event["type"])
        assertEquals(listOf("A", "B"), messageMaps(event).map { it["id"] })
    }

    @Test
    fun `empty timeline is an empty list, not a missing key`() {
        val event = ChatSerialization.publicMessagesEvent(emptyList(), me)

        assertEquals(emptyList<Any?>(), event["messages"])
    }

    @Test
    fun `health report line is left out of the public timeline`() {
        // Exactly what MessageHandler.handleHealthReport() hands the delegate.
        val healthReport = message(
            id = "abcdef012345",
            sender = "匿名回報",
            content = "[HEALTH REPORT] Status: 安全\nLocation: 位置未提供"
        )
        val chat = message(id = "CHAT", content = "anyone near the station?")

        val event = ChatSerialization.publicMessagesEvent(listOf(healthReport, chat), me)

        assertEquals(listOf("CHAT"), messageMaps(event).map { it["id"] })
    }

    @Test
    fun `chat text that merely quotes the health report prefix stays visible`() {
        val quoted = message(sender = "alice", content = "[HEALTH REPORT] is what the app shows?")

        val event = ChatSerialization.publicMessagesEvent(listOf(quoted), me)

        assertEquals(1, messageMaps(event).size)
        assertFalse(ChatSerialization.isHealthReportLine(quoted))
    }

    // --- mesh nickname -----------------------------------------------------------------------

    @Test
    fun `nickname event carries the nickname`() {
        assertEquals(
            mapOf("type" to "chat_nickname", "nickname" to "anon4821"),
            ChatSerialization.nicknameEvent("anon4821")
        )
    }

    @Test
    fun `nickname event carries the nickname exactly as upstream holds it`() {
        // Upstream neither trims nor rejects a blank nickname (ChatViewModel.setNickname), so
        // the projection must not either.
        listOf("", "  ", " bob ", "小明").forEach { nickname ->
            assertEquals("'$nickname'", nickname, ChatSerialization.nicknameEvent(nickname)["nickname"])
        }
    }

    @Test
    fun `nickname event survives a StandardMessageCodec round trip`() {
        val event = ChatSerialization.nicknameEvent("小明 anon")
        val codec = StandardMessageCodec.INSTANCE
        val encoded = codec.encodeMessage(event)!!.also { it.rewind() }

        assertEquals(event, codec.decodeMessage(encoded))
    }

    @Suppress("UNCHECKED_CAST")
    private fun messageMaps(event: Map<String, Any?>) = event["messages"] as List<Map<String, Any?>>
}
