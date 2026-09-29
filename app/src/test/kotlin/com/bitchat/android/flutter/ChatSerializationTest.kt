package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.DeliveryStatus
import com.bitchat.android.ui.CommandSuggestion
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
                "isSystem" to false,
                "mentionsMe" to false,
                "mentionSpans" to emptyList<Any?>()
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

    // --- mentions (#54) ------------------------------------------------------------------------

    @Test
    fun `a message mentioning us is flagged and its mention tokens are carried as spans`() {
        val map = ChatSerialization.message(message(content = "@bob and @me#1a2b, look"), me)

        assertEquals(true, map["mentionsMe"])
        assertEquals(
            listOf(
                mapOf("start" to 0, "end" to 4, "isMe" to false),
                mapOf("start" to 9, "end" to 17, "isMe" to true)
            ),
            map["mentionSpans"]
        )
    }

    @Test
    fun `our own message keeps its spans but does not mention us`() {
        val map = ChatSerialization.message(message(sender = "me", content = "reminder for @me"), me)

        assertEquals(false, map["mentionsMe"])
        assertEquals(listOf(mapOf("start" to 13, "end" to 16, "isMe" to true)), map["mentionSpans"])
    }

    @Test
    fun `a system line carries no mention spans, as upstream renders it as plain text`() {
        val map = ChatSerialization.message(
            message(sender = "system", senderPeerID = null, content = "online users: @me, @bob"),
            me
        )

        assertEquals(false, map["mentionsMe"])
        assertEquals(emptyList<Any?>(), map["mentionSpans"])
    }

    @Test
    fun `a nickname change re-evaluates who is mentioned`() {
        val msg = message(content = "hi @bob")

        assertEquals(false, ChatSerialization.message(msg, me)["mentionsMe"])
        assertEquals(true, ChatSerialization.message(msg, me.copy(nickname = "bob"))["mentionsMe"])
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
                message(id = "M$i", content = "hi @me and @bob", mentions = listOf("me"), deliveryStatus = status)
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

    // --- mesh peers ----------------------------------------------------------------------------

    private val alice = "1111111111111111"
    private val bob = "2222222222222222"

    private fun peerInputs(
        connectedPeers: List<String>,
        peerNicknames: Map<String, String> = emptyMap(),
        peerRSSI: Map<String, Int> = emptyMap(),
        peerDirect: Map<String, Boolean> = emptyMap(),
        wifiAwarePeerIDs: Set<String> = emptySet()
    ) = ChatPeerList.Inputs(
        myPeerID = me.peerID,
        connectedPeers = connectedPeers,
        peerNicknames = peerNicknames,
        peerRSSI = peerRSSI,
        peerDirect = peerDirect,
        wifiAwarePeerIDs = wifiAwarePeerIDs,
        privateChats = emptyMap()
    )

    @Test
    fun `peer maps every bridge field`() {
        val event = ChatSerialization.peersEvent(
            peerInputs(
                connectedPeers = listOf(alice),
                peerNicknames = mapOf(alice to "alice"),
                peerRSSI = mapOf(alice to -67),
                peerDirect = mapOf(alice to true)
            )
        ) { false }

        assertEquals(
            listOf(
                mapOf(
                    "peerID" to alice,
                    "nickname" to "alice",
                    "displayName" to "alice",
                    "displaySuffix" to "",
                    "rssi" to -67,
                    "signalBars" to 2,
                    "connection" to "bluetooth"
                )
            ),
            peerMaps(event)
        )
    }

    @Test
    fun `peer upstream knows little about keeps its nulls`() {
        val peer = peerMaps(ChatSerialization.peersEvent(peerInputs(connectedPeers = listOf(alice))) { false }).single()

        assertNull(peer["nickname"])
        assertNull(peer["rssi"])
        assertNull(peer["signalBars"])
        assertEquals(alice.take(12), peer["displayName"])
        assertEquals("routed", peer["connection"])
        assertTrue("null values are present, not missing keys", peer.containsKey("rssi"))
    }

    @Test
    fun `peers event carries the online count and the rows in list order`() {
        val event = ChatSerialization.peersEvent(
            peerInputs(
                connectedPeers = listOf(bob, me.peerID, alice),
                peerNicknames = mapOf(alice to "alice", bob to "bob")
            )
        ) { false }

        assertEquals("chat_peers", event["type"])
        assertEquals(2, event["onlineCount"])
        assertEquals(listOf(alice, bob), peerMaps(event).map { it["peerID"] })
    }

    @Test
    fun `nobody connected is a zero count and an empty list, not missing keys`() {
        val event = ChatSerialization.peersEvent(peerInputs(connectedPeers = emptyList())) { false }

        assertEquals(0, event["onlineCount"])
        assertEquals(emptyList<Any?>(), event["peers"])
    }

    @Test
    fun `peers event survives a StandardMessageCodec round trip`() {
        val event = ChatSerialization.peersEvent(
            peerInputs(
                connectedPeers = listOf(alice, bob),
                peerNicknames = mapOf(alice to "小明#beef", bob to "小明#0a1b"),
                peerRSSI = mapOf(alice to -40),
                peerDirect = mapOf(alice to true, bob to false),
                wifiAwarePeerIDs = setOf(bob)
            )
        ) { false }
        val codec = StandardMessageCodec.INSTANCE
        val encoded = codec.encodeMessage(event)!!.also { it.rewind() }

        assertEquals(event, codec.decodeMessage(encoded))
    }

    // --- suggestions (#54) ---------------------------------------------------------------------

    @Test
    fun `command suggestion maps every upstream field`() {
        assertEquals(
            mapOf(
                "command" to "/m",
                "aliases" to listOf("/msg"),
                "syntax" to "<nickname> [message]",
                "description" to "send private message"
            ),
            ChatSerialization.commandSuggestion(
                CommandSuggestion("/m", listOf("/msg"), "<nickname> [message]", "send private message")
            )
        )
    }

    @Test
    fun `command suggestion without syntax or aliases keeps a null and an empty list`() {
        val map = ChatSerialization.commandSuggestion(CommandSuggestion("/w", emptyList(), null, "see who's online"))

        assertEquals(emptyList<String>(), map["aliases"])
        assertTrue(map.containsKey("syntax"))
        assertNull(map["syntax"])
    }

    @Test
    fun `suggestions event carries both popups in upstream order`() {
        val event = ChatSerialization.suggestionsEvent(
            showCommands = true,
            commands = listOf(
                CommandSuggestion("/hug", emptyList(), "<nickname>", "send someone a warm hug"),
                CommandSuggestion("/w", emptyList(), null, "see who's online")
            ),
            showMentions = true,
            mentions = listOf("bob", "alice")
        )

        assertEquals("chat_suggestions", event["type"])
        assertEquals(true, event["showCommands"])
        assertEquals(listOf("/hug", "/w"), commandMaps(event).map { it["command"] })
        assertEquals(true, event["showMentions"])
        assertEquals(listOf("bob", "alice"), event["mentions"])
    }

    @Test
    fun `no suggestions is two hidden, empty popups, not missing keys`() {
        assertEquals(
            mapOf(
                "type" to "chat_suggestions",
                "showCommands" to false,
                "commands" to emptyList<Any?>(),
                "showMentions" to false,
                "mentions" to emptyList<String>()
            ),
            ChatSerialization.suggestionsEvent(false, emptyList(), false, emptyList())
        )
    }

    @Test
    fun `suggestions event survives a StandardMessageCodec round trip`() {
        val event = ChatSerialization.suggestionsEvent(
            showCommands = true,
            commands = listOf(CommandSuggestion("/j", listOf("/join"), "<channel>", "join or create a channel")),
            showMentions = true,
            mentions = listOf("小明", "anon1234")
        )
        val codec = StandardMessageCodec.INSTANCE
        val encoded = codec.encodeMessage(event)!!.also { it.rewind() }

        assertEquals(event, codec.decodeMessage(encoded))
    }

    // --- private chats (#55) ------------------------------------------------------------------

    private val contact = "contact_" + "c".repeat(64)

    @Test
    fun `selected private peer event carries the focus`() {
        val focus = ChatPrivateChat.Focus(
            peerID = alice,
            conversationID = contact,
            displayName = "alice",
            draft = "half a senten"
        )

        assertEquals(
            mapOf(
                "type" to "chat_selected_private_peer",
                "peerID" to alice,
                "conversationID" to contact,
                "displayName" to "alice",
                "draft" to "half a senten"
            ),
            ChatSerialization.selectedPrivatePeerEvent(focus)
        )
    }

    @Test
    fun `no private chat in focus is all nulls, not missing keys`() {
        assertEquals(
            mapOf(
                "type" to "chat_selected_private_peer",
                "peerID" to null,
                "conversationID" to null,
                "displayName" to null,
                "draft" to null
            ),
            ChatSerialization.selectedPrivatePeerEvent(null)
        )
    }

    @Test
    fun `private chats event carries each conversation under upstream's key, in order`() {
        val event = ChatSerialization.privateChatsEvent(
            mapOf(
                contact to listOf(message(id = "P1", isPrivate = true), message(id = "P2", isPrivate = true)),
                bob to listOf(message(id = "P3", senderPeerID = bob, isPrivate = true))
            ),
            me
        )

        assertEquals("chat_private_chats", event["type"])
        assertEquals(
            mapOf(contact to listOf("P1", "P2"), bob to listOf("P3")),
            privateChatMaps(event).mapValues { (_, messages) -> messages.map { it["id"] } }
        )
    }

    @Test
    fun `a private message is serialized like any other, our own with its delivery status`() {
        val sent = message(
            id = "P1",
            sender = "me",
            senderPeerID = me.peerID,
            isPrivate = true,
            deliveryStatus = DeliveryStatus.Sent
        )

        val map = privateChatMaps(ChatSerialization.privateChatsEvent(mapOf(contact to listOf(sent)), me))
            .getValue(contact).single()

        assertEquals(ChatSerialization.message(sent, me), map)
        assertEquals(true, map["isPrivate"])
        assertEquals(true, map["isFromSelf"])
        assertEquals(mapOf("kind" to "sent"), map["deliveryStatus"])
    }

    @Test
    fun `no private chats is an empty map, not a missing key`() {
        assertEquals(
            mapOf("type" to "chat_private_chats", "chats" to emptyMap<String, Any?>()),
            ChatSerialization.privateChatsEvent(emptyMap(), me)
        )
    }

    @Test
    fun `private chat events survive a StandardMessageCodec round trip`() {
        val codec = StandardMessageCodec.INSTANCE
        listOf(
            ChatSerialization.selectedPrivatePeerEvent(ChatPrivateChat.Focus(alice, contact, "小明", "")),
            ChatSerialization.selectedPrivatePeerEvent(null),
            ChatSerialization.privateChatsEvent(
                mapOf(contact to listOf(message(isPrivate = true, deliveryStatus = DeliveryStatus.Read("bob", statusAt)))),
                me
            )
        ).forEach { event ->
            val encoded = codec.encodeMessage(event)!!.also { it.rewind() }

            assertEquals(event, codec.decodeMessage(encoded))
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun privateChatMaps(event: Map<String, Any?>) =
        event["chats"] as Map<String, List<Map<String, Any?>>>

    @Suppress("UNCHECKED_CAST")
    private fun commandMaps(event: Map<String, Any?>) = event["commands"] as List<Map<String, Any?>>

    @Suppress("UNCHECKED_CAST")
    private fun peerMaps(event: Map<String, Any?>) = event["peers"] as List<Map<String, Any?>>

    @Suppress("UNCHECKED_CAST")
    private fun messageMaps(event: Map<String, Any?>) = event["messages"] as List<Map<String, Any?>>
}
