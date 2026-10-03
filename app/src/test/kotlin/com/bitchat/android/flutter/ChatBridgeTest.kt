package com.bitchat.android.flutter

import com.bitchat.android.mesh.PeerInfo
import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.BitchatMessageType
import com.bitchat.android.model.DeliveryStatus
import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.ui.CommandSuggestion
import com.bitchat.android.ui.ConversationSummary
import com.bitchat.android.ui.DirectMessageTransport
import io.flutter.plugin.common.MethodCall
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.anyOrNull
import org.mockito.kotlin.doAnswer
import org.mockito.kotlin.doSuspendableAnswer
import org.mockito.kotlin.eq
import org.mockito.kotlin.inOrder
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.same
import org.mockito.kotlin.verify
import org.mockito.kotlin.verifyBlocking
import org.mockito.kotlin.whenever
import java.util.Date

@OptIn(ExperimentalCoroutinesApi::class)
class ChatBridgeTest {

    private val poster = ManualPoster()
    private val events = BridgeEventEmitter(postToMain = poster, logDropped = {})
    private val sink = RecordingSink()

    // Projection work only runs when a test advances this scheduler.
    private val dispatcher = StandardTestDispatcher()
    private val scope = CoroutineScope(dispatcher + Job())

    private val messages = MutableStateFlow<List<BitchatMessage>>(emptyList())
    private val nickname = MutableStateFlow("me")
    private val connectedPeers = MutableStateFlow<List<String>>(emptyList())
    private val peerNicknames = MutableStateFlow<Map<String, String>>(emptyMap())
    private val peerRSSI = MutableStateFlow<Map<String, Int>>(emptyMap())
    private val peerDirect = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    private val privateChats = MutableStateFlow<Map<String, List<BitchatMessage>>>(emptyMap())
    private val wifiAwarePeers = MutableStateFlow<Map<String, String>>(emptyMap())
    private val showCommandSuggestions = MutableStateFlow(false)
    private val commandSuggestions = MutableStateFlow<List<CommandSuggestion>>(emptyList())
    private val showMentionSuggestions = MutableStateFlow(false)
    private val mentionSuggestions = MutableStateFlow<List<String>>(emptyList())
    private val selectedPrivateChatPeer = MutableStateFlow<String?>(null)
    private val unreadPrivateMessages = MutableStateFlow<Set<String>>(emptySet())
    private val conversations = MutableStateFlow<List<ConversationSummary>>(emptyList())
    private val privateChatSheetPeer = MutableStateFlow<String?>(null)
    private val favoritePeers = MutableStateFlow<Set<String>>(emptySet())
    private val peerFavoritedUs = MutableStateFlow<Set<String>>(emptySet())
    private val peerFingerprints = MutableStateFlow<Map<String, String>>(emptyMap())
    private val drafts = mutableMapOf<String, String>()

    /** Upstream's favourites store and block list, as ChatBridge reads them. */
    private val records = FakeRecords()

    /** Upstream's contact records, as ChatBridge reads them; unknown IDs resolve to themselves. */
    private val contacts = mutableMapOf<String, ChatPrivateChat.Contact>()
    private val viewModel = mock<ChatViewModel>().also { vm ->
        whenever(vm.messages).thenReturn(messages)
        // Not thenReturn: in bytecode ChatViewModel has two getNickname() methods that differ
        // only in return type (this StateFlow property and BluetoothMeshDelegate's String?).
        // Mockito looks the method up by name and parameters, gets either one depending on the
        // JVM, and thenReturn's return-type check then fails at random. thenAnswer is not checked.
        whenever(vm.nickname).thenAnswer { nickname }
        whenever(vm.myPeerID).thenReturn(MY_PEER_ID)
        whenever(vm.connectedPeers).thenAnswer { connectedPeers }
        whenever(vm.peerNicknames).thenAnswer { peerNicknames }
        whenever(vm.peerRSSI).thenAnswer { peerRSSI }
        whenever(vm.peerDirect).thenAnswer { peerDirect }
        whenever(vm.privateChats).thenAnswer { privateChats }
        whenever(vm.showCommandSuggestions).thenAnswer { showCommandSuggestions }
        whenever(vm.commandSuggestions).thenAnswer { commandSuggestions }
        whenever(vm.showMentionSuggestions).thenAnswer { showMentionSuggestions }
        whenever(vm.mentionSuggestions).thenAnswer { mentionSuggestions }
        whenever(vm.selectedPrivateChatPeer).thenAnswer { selectedPrivateChatPeer }
        whenever(vm.unreadPrivateMessages).thenAnswer { unreadPrivateMessages }
        whenever(vm.conversations).thenAnswer { conversations }
        whenever(vm.privateChatSheetPeer).thenAnswer { privateChatSheetPeer }
        whenever(vm.favoritePeers).thenAnswer { favoritePeers }
        whenever(vm.peerFavoritedUs).thenAnswer { peerFavoritedUs }
        whenever(vm.peerFingerprints).thenAnswer { peerFingerprints }
        whenever(vm.conversationDraft(anyOrNull())).thenAnswer { drafts[it.arguments[0]] ?: "" }
        whenever(vm.resolvePeerDisplayNameForFingerprint(any())).thenAnswer { (it.arguments[0] as String).take(8) }
    }
    private val pendingNavigation = PendingChatNavigation()
    private val bridge = ChatBridge(viewModel, events, scope, wifiAwarePeers, pendingNavigation, records) { id ->
        contacts[id] ?: ChatPrivateChat.Contact(id, meshPeerID = null, displayName = null, favoriteNickname = null)
    }

    // --- method dispatch ---------------------------------------------------------------------

    @Test
    fun `chat bridge declines methods it does not own`() {
        val result = RecordingResult()

        val claimed = bridge.handle(MethodCall("noSuchChatMethod", null), result)

        assertFalse(claimed)
        assertEquals(emptyList<String>(), result.calls)
    }

    @Test
    fun `method unknown to both bridges ends in notImplemented`() {
        val systemBridge = BridgeMethodHandler { _, _ -> false }
        val result = RecordingResult()

        BridgeMethodDispatcher(listOf(systemBridge, bridge))
            .onMethodCall(MethodCall("noSuchMethod", null), result)

        assertEquals(listOf("notImplemented"), result.calls)
    }

    @Test
    fun `legacy sendMessage with peerId and isPublic is no longer answered`() {
        val systemBridge = BridgeMethodHandler { _, _ -> false }
        val result = RecordingResult()

        BridgeMethodDispatcher(listOf(systemBridge, bridge)).onMethodCall(
            MethodCall("sendMessage", mapOf("peerId" to "x", "text" to "hi", "isPublic" to false)),
            result
        )

        assertEquals(listOf("notImplemented"), result.calls)
        verify(viewModel, never()).sendMessage(any(), any())
    }

    @Test
    fun `sendMessage forwards the trimmed text and answers with its acceptance`() {
        acceptSends(true)
        val result = RecordingResult()

        val claimed = bridge.handle(sendCall("  hello mesh \n"), result)

        assertTrue(claimed)
        verify(viewModel).sendMessage(eq("hello mesh"), any())
        assertEquals(listOf("success:true"), result.calls)
    }

    @Test
    fun `commands are forwarded untouched for the view model to handle`() {
        acceptSends(true)

        bridge.handle(sendCall("/w"), RecordingResult())

        verify(viewModel).sendMessage(eq("/w"), any())
    }

    @Test
    fun `send the view model refuses is answered false`() {
        acceptSends(false)
        val result = RecordingResult()

        bridge.handle(sendCall("hello"), result)

        assertEquals(listOf("success:false"), result.calls)
    }

    @Test
    fun `blank text is not sent`() {
        listOf("", "   ", "\n\t ").forEach { text ->
            val result = RecordingResult()

            val claimed = bridge.handle(sendCall(text), result)

            assertTrue(claimed)
            assertEquals("'$text'", listOf("success:false"), result.calls)
        }
        verify(viewModel, never()).sendMessage(any(), any())
    }

    @Test
    fun `sendMessage without a text string is rejected`() {
        listOf(
            MethodCall(ChatBridge.METHOD_SEND_MESSAGE, null),
            MethodCall(ChatBridge.METHOD_SEND_MESSAGE, mapOf("text" to 42)),
            MethodCall(ChatBridge.METHOD_SEND_MESSAGE, "hello")
        ).forEach { call ->
            val result = RecordingResult()

            bridge.handle(call, result)

            assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        }
        verify(viewModel, never()).sendMessage(any(), any())
    }

    // --- mesh nickname -----------------------------------------------------------------------

    @Test
    fun `setNickname forwards the nickname untouched to the view model`() {
        val result = RecordingResult()

        val claimed = bridge.handle(setNicknameCall("  bob  "), result)

        assertTrue(claimed)
        verify(viewModel).setNickname("  bob  ")
        assertEquals(listOf("success:null"), result.calls)
    }

    @Test
    fun `blank nickname is left for the view model to handle`() {
        // Upstream accepts a blank nickname (announce then falls back to the peer ID in
        // NicknameProvider); the bridge must not add a rule of its own.
        listOf("", "   ").forEach { nickname ->
            val result = RecordingResult()

            bridge.handle(setNicknameCall(nickname), result)

            verify(viewModel).setNickname(nickname)
            assertEquals("'$nickname'", listOf("success:null"), result.calls)
        }
    }

    @Test
    fun `long nickname is left for the view model to handle`() {
        val long = "n".repeat(300)

        bridge.handle(setNicknameCall(long), RecordingResult())

        verify(viewModel).setNickname(long)
    }

    @Test
    fun `setNickname without a nickname string is rejected`() {
        listOf(
            MethodCall(ChatBridge.METHOD_SET_NICKNAME, null),
            MethodCall(ChatBridge.METHOD_SET_NICKNAME, mapOf("nickname" to 42)),
            MethodCall(ChatBridge.METHOD_SET_NICKNAME, mapOf("name" to "bob")),
            MethodCall(ChatBridge.METHOD_SET_NICKNAME, "bob")
        ).forEach { call ->
            val result = RecordingResult()

            val claimed = bridge.handle(call, result)

            assertTrue(claimed)
            assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        }
        verify(viewModel, never()).setNickname(any())
    }

    @Test
    fun `getNickname answers the view model's current nickname`() {
        nickname.value = "anon4821"
        val result = RecordingResult()

        val claimed = bridge.handle(MethodCall(ChatBridge.METHOD_GET_NICKNAME, null), result)

        assertTrue(claimed)
        assertEquals(listOf("success:anon4821"), result.calls)
    }

    @Test
    fun `legacy register and getProfile are not answered`() {
        val systemBridge = BridgeMethodHandler { _, _ -> false }
        val dispatcher = BridgeMethodDispatcher(listOf(systemBridge, bridge))

        listOf(
            MethodCall("register", mapOf("nickname" to "Real Name")),
            MethodCall("getProfile", null)
        ).forEach { call ->
            val result = RecordingResult()

            dispatcher.onMethodCall(call, result)

            assertEquals(call.method, listOf("notImplemented"), result.calls)
        }
        verify(viewModel, never()).setNickname(any())
    }

    @Test
    fun `Dart subscribing receives the current nickname`() {
        nickname.value = "anon4821"

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf("anon4821"), nicknames())
    }

    @Test
    fun `requestSnapshot pushes the current nickname`() {
        events.onListen(null, sink)
        poster.runAll()
        sink.events.clear()
        nickname.value = "anon4821"

        bridge.handle(MethodCall(ChatBridge.METHOD_REQUEST_SNAPSHOT, null), RecordingResult())
        poster.runAll()

        assertEquals(listOf("anon4821"), nicknames())
    }

    @Test
    fun `nickname set through the bridge is pushed back as a snapshot`() {
        doAnswer { invocation ->
            nickname.value = invocation.arguments[0] as String
            null
        }.whenever(viewModel).setNickname(any())
        events.onListen(null, sink)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        sink.events.clear()

        bridge.handle(setNicknameCall("bob"), RecordingResult())
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf("bob"), nicknames())
    }

    @Test
    fun `nickname changed elsewhere in upstream is pushed after the debounce`() {
        events.onListen(null, sink)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        sink.events.clear()

        // e.g. the panic reset back to a fresh anonXXXX
        nickname.value = "anon1234"
        dispatcher.scheduler.advanceTimeBy(ChatBridge.SNAPSHOT_DEBOUNCE_MS / 2)
        dispatcher.scheduler.runCurrent()
        poster.runAll()
        assertEquals("still inside the debounce window", emptyList<String>(), nicknames())

        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf("anon1234"), nicknames())
    }

    // --- mesh peers --------------------------------------------------------------------------

    @Test
    fun `Dart subscribing receives the current peer list`() {
        connectedPeers.value = listOf(ALICE, MY_PEER_ID)
        peerNicknames.value = mapOf(ALICE to "alice")

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(1 to listOf(ALICE)), peerSnapshots())
    }

    @Test
    fun `requestSnapshot pushes the current peer list`() {
        events.onListen(null, sink)
        poster.runAll()
        sink.events.clear()
        connectedPeers.value = listOf(ALICE)

        bridge.handle(MethodCall(ChatBridge.METHOD_REQUEST_SNAPSHOT, null), RecordingResult())
        poster.runAll()

        assertEquals(listOf(1 to listOf(ALICE)), peerSnapshots())
    }

    @Test
    fun `a peer joining and leaving is pushed after the debounce`() {
        settleAndClear()

        connectedPeers.value = listOf(ALICE)
        dispatcher.scheduler.advanceTimeBy(ChatBridge.SNAPSHOT_DEBOUNCE_MS / 2)
        connectedPeers.value = listOf(ALICE, BOB)
        dispatcher.scheduler.runCurrent()
        poster.runAll()
        assertEquals("still inside the debounce window", emptyList<Any?>(), peerSnapshots())

        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        assertEquals(listOf(2 to listOf(ALICE, BOB)), peerSnapshots())
        sink.events.clear()

        connectedPeers.value = listOf(BOB)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        assertEquals(listOf(1 to listOf(BOB)), peerSnapshots())
    }

    @Test
    fun `a burst across several peer flows is pushed as one consistent snapshot`() {
        settleAndClear()

        connectedPeers.value = listOf(ALICE)
        peerNicknames.value = mapOf(ALICE to "alice")
        peerRSSI.value = mapOf(ALICE to -50)
        peerDirect.value = mapOf(ALICE to true)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        val peer = peerRows().single().single()
        assertEquals(listOf("alice", -50, "bluetooth"), listOf(peer["displayName"], peer["rssi"], peer["connection"]))
    }

    @Test
    fun `rssi and nickname refreshes are pushed`() {
        connectedPeers.value = listOf(ALICE)
        settleAndClear()

        peerRSSI.value = mapOf(ALICE to -80)
        peerNicknames.value = mapOf(ALICE to "alice")
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        val peer = peerRows().single().single()
        assertEquals(listOf("alice", -80, 1), listOf(peer["displayName"], peer["rssi"], peer["signalBars"]))
    }

    @Test
    fun `a wifi aware link is pushed as the peer's connection`() {
        connectedPeers.value = listOf(ALICE)
        peerDirect.value = mapOf(ALICE to false)
        settleAndClear()

        wifiAwarePeers.value = mapOf(ALICE to "fe80::1")
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals("wifiAware", peerRows().single().single()["connection"])
    }

    @Test
    fun `directness missing from peerDirect is read from the mesh peer info`() {
        whenever(viewModel.getMeshPeerInfo(ALICE)).thenReturn(peerInfo(ALICE, isDirect = true))
        connectedPeers.value = listOf(ALICE, BOB)

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(
            listOf("bluetooth", "routed"),
            peerRows().single().map { it["connection"] }
        )
    }

    @Test
    fun `a failing mesh peer lookup counts as routed`() {
        whenever(viewModel.getMeshPeerInfo(ALICE)).thenThrow(IllegalStateException("mesh gone"))
        connectedPeers.value = listOf(ALICE)

        events.onListen(null, sink)
        poster.runAll()

        assertEquals("routed", peerRows().single().single()["connection"])
    }

    // --- mention and command suggestions (#54) --------------------------------------------------

    @Test
    fun `updateInput makes upstream's text-change calls in the native composer's order`() {
        val result = RecordingResult()

        val claimed = bridge.handle(updateInputCall("/h"), result)

        assertTrue(claimed)
        inOrder(viewModel) {
            // No draft for the public composer: upstream ignores a null conversation.
            verify(viewModel).setConversationDraft(null, "/h")
            verify(viewModel).updateCommandSuggestions("/h")
            verify(viewModel).updateMentionSuggestions("/h")
        }
        assertEquals(listOf("success:null"), result.calls)
    }

    @Test
    fun `updateInput from the private composer only saves its draft, as the native private chat does`() {
        // PrivateChatSheet shows no popups and leaves the shared suggestion state alone.
        val result = RecordingResult()

        val claimed = bridge.handle(updateInputCall("/hug al", privateChat = ALICE), result)

        assertTrue(claimed)
        verify(viewModel).setConversationDraft(ALICE, "/hug al")
        verify(viewModel, never()).updateCommandSuggestions(any())
        verify(viewModel, never()).updateMentionSuggestions(any())
        assertEquals(listOf("success:null"), result.calls)
    }

    @Test
    fun `updateInput with a privateChat that is not a string is rejected`() {
        val result = RecordingResult()

        bridge.handle(
            MethodCall(ChatBridge.METHOD_UPDATE_INPUT, mapOf("text" to "hi", "privateChat" to 7)),
            result
        )

        assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        verify(viewModel, never()).updateCommandSuggestions(any())
    }

    @Test
    fun `updateInput passes the text untouched, blank included`() {
        listOf("", "  @al", "hi @").forEach { text ->
            bridge.handle(updateInputCall(text), RecordingResult())

            verify(viewModel).updateCommandSuggestions(text)
            verify(viewModel).updateMentionSuggestions(text)
        }
    }

    @Test
    fun `updateInput without a text string is rejected`() {
        listOf(
            MethodCall(ChatBridge.METHOD_UPDATE_INPUT, null),
            MethodCall(ChatBridge.METHOD_UPDATE_INPUT, mapOf("text" to 42)),
            MethodCall(ChatBridge.METHOD_UPDATE_INPUT, "/h")
        ).forEach { call ->
            val result = RecordingResult()

            val claimed = bridge.handle(call, result)

            assertTrue(claimed)
            assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        }
        verify(viewModel, never()).updateCommandSuggestions(any())
        verify(viewModel, never()).updateMentionSuggestions(any())
    }

    @Test
    fun `selectCommandSuggestion hands upstream its own suggestion and answers the new input`() {
        val hug = CommandSuggestion("/hug", emptyList(), "<nickname>", "send someone a warm hug")
        commandSuggestions.value = listOf(CLEAR, hug)
        whenever(viewModel.selectCommandSuggestion(any())).thenAnswer { invocation ->
            "${(invocation.arguments[0] as CommandSuggestion).command} "
        }
        val result = RecordingResult()

        val claimed = bridge.handle(selectCommandCall("/hug"), result)

        assertTrue(claimed)
        verify(viewModel).selectCommandSuggestion(same(hug))
        assertEquals(listOf("success:/hug "), result.calls)
    }

    @Test
    fun `a command upstream no longer suggests answers null and selects nothing`() {
        commandSuggestions.value = listOf(CLEAR)
        val result = RecordingResult()

        bridge.handle(selectCommandCall("/hug"), result)

        assertEquals(listOf("success:null"), result.calls)
        verify(viewModel, never()).selectCommandSuggestion(any())
    }

    @Test
    fun `selectCommandSuggestion without a command string is rejected`() {
        commandSuggestions.value = listOf(CLEAR)
        listOf(
            MethodCall(ChatBridge.METHOD_SELECT_COMMAND_SUGGESTION, null),
            MethodCall(ChatBridge.METHOD_SELECT_COMMAND_SUGGESTION, mapOf("command" to 1)),
            MethodCall(ChatBridge.METHOD_SELECT_COMMAND_SUGGESTION, mapOf("suggestion" to "/clear")),
            MethodCall(ChatBridge.METHOD_SELECT_COMMAND_SUGGESTION, "/clear")
        ).forEach { call ->
            val result = RecordingResult()

            bridge.handle(call, result)

            assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        }
        verify(viewModel, never()).selectCommandSuggestion(any())
    }

    @Test
    fun `selectMentionSuggestion forwards nickname and current text and answers the new input`() {
        whenever(viewModel.selectMentionSuggestion("alice", "hi @al")).thenReturn("hi @alice ")
        val result = RecordingResult()

        val claimed = bridge.handle(selectMentionCall("alice", "hi @al"), result)

        assertTrue(claimed)
        assertEquals(listOf("success:hi @alice "), result.calls)
    }

    @Test
    fun `selectMentionSuggestion without both strings is rejected`() {
        listOf(
            MethodCall(ChatBridge.METHOD_SELECT_MENTION_SUGGESTION, null),
            MethodCall(ChatBridge.METHOD_SELECT_MENTION_SUGGESTION, mapOf("nickname" to "alice")),
            MethodCall(ChatBridge.METHOD_SELECT_MENTION_SUGGESTION, mapOf("currentText" to "@al")),
            MethodCall(ChatBridge.METHOD_SELECT_MENTION_SUGGESTION, mapOf("nickname" to 1, "currentText" to "@al"))
        ).forEach { call ->
            val result = RecordingResult()

            bridge.handle(call, result)

            assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        }
        verify(viewModel, never()).selectMentionSuggestion(any(), any())
    }

    @Test
    fun `clearSuggestions forwards to the view model`() {
        val result = RecordingResult()

        val claimed = bridge.handle(MethodCall(ChatBridge.METHOD_CLEAR_SUGGESTIONS, null), result)

        assertTrue(claimed)
        verify(viewModel).clearSuggestions()
        assertEquals(listOf("success:null"), result.calls)
    }

    @Test
    fun `Dart subscribing receives the current suggestions`() {
        showCommandSuggestions.value = true
        commandSuggestions.value = listOf(CLEAR)
        showMentionSuggestions.value = true
        mentionSuggestions.value = listOf("alice")

        events.onListen(null, sink)
        poster.runAll()

        val event = suggestionEvents().single()
        assertEquals(
            listOf(true, true, listOf("alice")),
            listOf(event["showCommands"], event["showMentions"], event["mentions"])
        )
        assertEquals(listOf("/clear"), suggestionCommands().single())
    }

    @Test
    fun `requestSnapshot pushes the current suggestions`() {
        settleAndClear()
        showMentionSuggestions.value = true
        mentionSuggestions.value = listOf("alice")

        bridge.handle(MethodCall(ChatBridge.METHOD_REQUEST_SNAPSHOT, null), RecordingResult())
        poster.runAll()

        assertEquals(listOf("alice"), suggestionEvents().single()["mentions"])
    }

    @Test
    fun `suggestions are pushed after the short input debounce, well before the snapshot one`() {
        settleAndClear()

        showMentionSuggestions.value = true
        mentionSuggestions.value = listOf("alice")
        dispatcher.scheduler.advanceTimeBy(ChatBridge.SUGGESTIONS_DEBOUNCE_MS - 1)
        dispatcher.scheduler.runCurrent()
        poster.runAll()
        assertEquals("still inside the debounce window", emptyList<Any?>(), suggestionEvents())

        dispatcher.scheduler.advanceTimeBy(1)
        dispatcher.scheduler.runCurrent()
        poster.runAll()

        assertEquals(listOf("alice"), suggestionEvents().single()["mentions"])
        assertTrue(ChatBridge.SUGGESTIONS_DEBOUNCE_MS < ChatBridge.SNAPSHOT_DEBOUNCE_MS)
    }

    @Test
    fun `one keystroke's writes to several suggestion flows are pushed as one snapshot`() {
        settleAndClear()

        // updateCommandSuggestions then updateMentionSuggestions, as one chat_updateInput runs them
        commandSuggestions.value = listOf(CLEAR)
        showCommandSuggestions.value = true
        showMentionSuggestions.value = false
        mentionSuggestions.value = emptyList()
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        val event = suggestionEvents().single()
        assertEquals(true, event["showCommands"])
        assertEquals(listOf("/clear"), suggestionCommands().single())
    }

    @Test
    fun `hiding the popups is pushed too`() {
        showCommandSuggestions.value = true
        commandSuggestions.value = listOf(CLEAR)
        settleAndClear()

        showCommandSuggestions.value = false
        commandSuggestions.value = emptyList()
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(false, suggestionEvents().single()["showCommands"])
        assertEquals(listOf(emptyList<Any?>()), suggestionCommands())
    }

    // --- private chats (#55) --------------------------------------------------------------------

    @Test
    fun `startPrivateChat hands the peer to upstream and answers with the focus it ends up with`() {
        // Upstream re-keys a peer with a known Noise key to its contact conversation.
        contacts[CONTACT] = ChatPrivateChat.Contact(CONTACT, meshPeerID = ALICE, displayName = "alice", favoriteNickname = null)
        peerNicknames.value = mapOf(ALICE to "alice")
        drafts[CONTACT] = "half a senten"
        whenever { viewModel.startPrivateChat(any()) }.thenAnswer {
            selectedPrivateChatPeer.value = CONTACT
            Unit
        }
        val result = RecordingResult()

        val claimed = bridge.handle(startPrivateChatCall(ALICE), result)
        dispatcher.scheduler.advanceUntilIdle()

        assertTrue(claimed)
        verifyBlocking(viewModel) { startPrivateChat(ALICE) }
        assertEquals(
            mapOf(
                "type" to ChatSerialization.EVENT_SELECTED_PRIVATE_PEER,
                "peerID" to CONTACT,
                "conversationID" to CONTACT,
                "displayName" to "alice",
                "draft" to "half a senten",
                "isFavorite" to false,
                "theyFavoritedUs" to false
            ),
            result.values.single()
        )
    }

    @Test
    fun `a start upstream refuses answers with no focus`() {
        // e.g. a blocked peer: upstream posts a system line and selects nothing.
        val result = RecordingResult()

        bridge.handle(startPrivateChatCall(ALICE), result)
        dispatcher.scheduler.advanceUntilIdle()

        assertEquals(null, (result.values.single() as Map<*, *>)["peerID"])
    }

    @Test
    fun `a failing start is reported, not left unanswered`() {
        whenever { viewModel.startPrivateChat(any()) }.thenThrow(IllegalStateException("db gone"))
        val result = RecordingResult()

        bridge.handle(startPrivateChatCall(ALICE), result)
        dispatcher.scheduler.advanceUntilIdle()

        assertEquals(listOf("error:PRIVATE_CHAT_FAILED"), result.calls)
    }

    @Test
    fun `startPrivateChat without a peer ID is rejected`() {
        listOf(
            MethodCall(ChatBridge.METHOD_START_PRIVATE_CHAT, null),
            MethodCall(ChatBridge.METHOD_START_PRIVATE_CHAT, mapOf("peerID" to 1)),
            MethodCall(ChatBridge.METHOD_START_PRIVATE_CHAT, mapOf("peerID" to "  ")),
            MethodCall(ChatBridge.METHOD_START_PRIVATE_CHAT, ALICE)
        ).forEach { call ->
            val result = RecordingResult()

            val claimed = bridge.handle(call, result)
            dispatcher.scheduler.advanceUntilIdle()

            assertTrue(claimed)
            assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        }
        verifyBlocking(viewModel, never()) { startPrivateChat(any()) }
    }

    @Test
    fun `endPrivateChat hands over to upstream and answers with no focus`() {
        selectedPrivateChatPeer.value = ALICE
        endClearsFocus()
        val result = RecordingResult()

        val claimed = bridge.handle(MethodCall(ChatBridge.METHOD_END_PRIVATE_CHAT, null), result)
        dispatcher.scheduler.advanceUntilIdle()

        assertTrue(claimed)
        verify(viewModel).endPrivateChat()
        assertEquals(null, (result.values.single() as Map<*, *>)["peerID"])
    }

    @Test
    fun `an end that arrives while a start is still loading is applied after it`() {
        // Leaving the private chat screen right after opening it: upstream's start is still in
        // its IO block and selects the peer when it finishes. Ending first would leave that late
        // selection behind, so the public composer's text would be routed privately.
        val historyLoaded = CompletableDeferred<Unit>()
        whenever { viewModel.startPrivateChat(any()) }.doSuspendableAnswer {
            historyLoaded.await()
            selectedPrivateChatPeer.value = ALICE
            Unit
        }
        endClearsFocus()
        val started = RecordingResult()
        val ended = RecordingResult()

        bridge.handle(startPrivateChatCall(ALICE), started)
        dispatcher.scheduler.advanceUntilIdle()
        bridge.handle(MethodCall(ChatBridge.METHOD_END_PRIVATE_CHAT, null), ended)
        dispatcher.scheduler.advanceUntilIdle()
        verify(viewModel, never()).endPrivateChat()

        historyLoaded.complete(Unit)
        dispatcher.scheduler.advanceUntilIdle()

        inOrder(viewModel) {
            verifyBlocking(viewModel) { startPrivateChat(ALICE) }
            verify(viewModel).endPrivateChat()
        }
        assertEquals(null, selectedPrivateChatPeer.value)
        assertEquals(ALICE, (started.values.single() as Map<*, *>)["peerID"])
        assertEquals(null, (ended.values.single() as Map<*, *>)["peerID"])
    }

    @Test
    fun `Dart subscribing receives the current focus and private chats`() {
        selectedPrivateChatPeer.value = ALICE
        privateChats.value = mapOf(ALICE to listOf(message("P1", senderPeerID = ALICE)))

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(ALICE), focusPeerIDs())
        assertEquals(listOf(mapOf(ALICE to listOf("P1"))), privateChatIds())
    }

    @Test
    fun `no focus is pushed as a null peer`() {
        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(null), focusPeerIDs())
    }

    @Test
    fun `a focus upstream sets by itself is pushed after the debounce`() {
        settleAndClear()

        // What `/m alice` does: CommandProcessor selects the peer, no Flutter call involved.
        selectedPrivateChatPeer.value = ALICE
        dispatcher.scheduler.advanceTimeBy(ChatBridge.SNAPSHOT_DEBOUNCE_MS / 2)
        dispatcher.scheduler.runCurrent()
        poster.runAll()
        assertEquals("still inside the debounce window", emptyList<Any?>(), focusPeerIDs())

        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        assertEquals(listOf(ALICE), focusPeerIDs())
        sink.events.clear()

        // ...and what /block, deleting the conversation or the panic reset do.
        selectedPrivateChatPeer.value = null
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        assertEquals(listOf(null), focusPeerIDs())
    }

    @Test
    fun `the focus title follows the peer's announced nickname`() {
        selectedPrivateChatPeer.value = ALICE
        settleAndClear()

        peerNicknames.value = mapOf(ALICE to "alice")
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals("alice", focusEvents().single()["displayName"])
    }

    @Test
    fun `a focus on an offline contact carries upstream's conversation key and recorded name`() {
        contacts[CONTACT] = ChatPrivateChat.Contact(CONTACT, meshPeerID = null, displayName = "alice", favoriteNickname = null)
        selectedPrivateChatPeer.value = CONTACT

        events.onListen(null, sink)
        poster.runAll()

        val focus = focusEvents().single()
        assertEquals(listOf(CONTACT, CONTACT, "alice", ""), listOf(focus["peerID"], focus["conversationID"], focus["displayName"], focus["draft"]))
    }

    @Test
    fun `private chats upstream changes are pushed after the debounce`() {
        settleAndClear()

        privateChats.value = mapOf(ALICE to listOf(message("P1", senderPeerID = ALICE)))
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(mapOf(ALICE to listOf("P1"))), privateChatIds())
    }

    // The composer guard. Where text goes is upstream's decision (ChatViewModel.sendMessage routes
    // by selectedPrivateChatPeer); the bridge only refuses text whose composer disagrees with it.

    @Test
    fun `the public composer's text is not sent while upstream has a private chat in focus`() {
        acceptSends(true)
        selectedPrivateChatPeer.value = ALICE
        val result = RecordingResult()

        bridge.handle(sendCall("meet at the gym"), result)

        assertEquals(listOf("success:false"), result.calls)
        verify(viewModel, never()).sendMessage(any(), any())
    }

    @Test
    fun `after endPrivateChat the public composer's text is sent to the public timeline again`() {
        acceptSends(true)
        selectedPrivateChatPeer.value = ALICE
        endClearsFocus()

        // Leaving the private chat screen, then sending from the public chat.
        bridge.handle(MethodCall(ChatBridge.METHOD_END_PRIVATE_CHAT, null), RecordingResult())
        dispatcher.scheduler.advanceUntilIdle()
        val result = RecordingResult()
        bridge.handle(sendCall("meet at the gym"), result)

        assertEquals(listOf("success:true"), result.calls)
        verify(viewModel).sendMessage(eq("meet at the gym"), any())
        assertEquals("sent with no private chat in focus", null, selectedPrivateChatPeer.value)
    }

    @Test
    fun `the private composer's text goes to upstream while its chat is in focus`() {
        acceptSends(true)
        selectedPrivateChatPeer.value = ALICE
        val result = RecordingResult()

        bridge.handle(sendCall("  see you  ", privateChat = ALICE), result)

        assertEquals(listOf("success:true"), result.calls)
        verify(viewModel).sendMessage(eq("see you"), any())
    }

    @Test
    fun `the private composer's text is not sent once upstream has left that chat`() {
        // Otherwise upstream would post it to the public timeline in the clear.
        acceptSends(true)
        listOf(null, BOB).forEach { focus ->
            selectedPrivateChatPeer.value = focus
            val result = RecordingResult()

            bridge.handle(sendCall("see you", privateChat = ALICE), result)

            assertEquals("focus $focus", listOf("success:false"), result.calls)
        }
        verify(viewModel, never()).sendMessage(any(), any())
    }

    @Test
    fun `sendMessage with a privateChat that is not a string is rejected`() {
        val result = RecordingResult()

        bridge.handle(MethodCall(ChatBridge.METHOD_SEND_MESSAGE, mapOf("text" to "hi", "privateChat" to true)), result)

        assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        verify(viewModel, never()).sendMessage(any(), any())
    }

    // --- delivery status and unread (#56) -------------------------------------------------------

    @Test
    fun `each delivery status upstream reaches is pushed with the private chats`() {
        val sent = privateMessage("P1", DeliveryStatus.Sending)
        privateChats.value = mapOf(ALICE to listOf(sent))
        settleAndClear()

        // What MessageManager and AppStateStore do on an ack or receipt: a copy with the new status
        // in a new map. The copy differs from the old message, so the StateFlow emits.
        listOf(
            DeliveryStatus.Delivered(ALICE, Date(1_700_000_001_000L)),
            DeliveryStatus.Read(ALICE, Date(1_700_000_002_000L))
        ).forEach { status ->
            privateChats.value = mapOf(ALICE to listOf(sent.copy(deliveryStatus = status)))
            dispatcher.scheduler.advanceUntilIdle()
            poster.runAll()
        }

        assertEquals(listOf("delivered", "read"), privateChatStatusKinds())
    }

    @Test
    fun `a queued message the router gives up on is pushed as failed, with upstream's reason`() {
        val sent = privateMessage("P1", DeliveryStatus.Sending)
        privateChats.value = mapOf(ALICE to listOf(sent))
        settleAndClear()

        // ChatViewModel's MessageRouter.onMessageExpired hook.
        privateChats.value =
            mapOf(ALICE to listOf(sent.copy(deliveryStatus = DeliveryStatus.Failed("Message expired before delivery"))))
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(
            listOf(mapOf("kind" to "failed", "reason" to "Message expired before delivery")),
            privateChatStatuses()
        )
    }

    @Test
    fun `Dart subscribing receives the current unread state`() {
        unreadPrivateMessages.value = setOf(CONTACT)
        conversations.value = listOf(summary(CONTACT, unreadCount = 2, connectedPeerID = ALICE))

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(
            listOf(
                mapOf(
                    "type" to ChatSerialization.EVENT_UNREAD,
                    "hasUnread" to true,
                    "conversations" to mapOf(CONTACT to 2)
                )
            ),
            unreadEvents()
        )
    }

    @Test
    fun `unread changes upstream makes are pushed after the debounce, down to zero on opening`() {
        settleAndClear()

        // A private message arrives in a chat that is not open.
        unreadPrivateMessages.value = setOf(CONTACT)
        conversations.value = listOf(summary(CONTACT, unreadCount = 1, connectedPeerID = ALICE))
        dispatcher.scheduler.advanceTimeBy(ChatBridge.SNAPSHOT_DEBOUNCE_MS / 2)
        dispatcher.scheduler.runCurrent()
        poster.runAll()
        assertEquals("still inside the debounce window", emptyList<Any?>(), unreadEvents())
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        assertEquals(listOf(mapOf(CONTACT to 1)), unreadEvents().map { it["conversations"] })
        sink.events.clear()

        // Opening it: upstream's startPrivateChat clears the mark and reads its messages.
        unreadPrivateMessages.value = emptySet()
        conversations.value = listOf(summary(CONTACT, unreadCount = 0, connectedPeerID = ALICE))
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(false to emptyMap<String, Int>()), unreadEvents().map { it["hasUnread"] to it["conversations"] })
    }

    @Test
    fun `peer rows carry their online conversation's unread count and follow it`() {
        connectedPeers.value = listOf(ALICE, BOB)
        peerNicknames.value = mapOf(ALICE to "alice", BOB to "bob")
        settleAndClear()

        conversations.value = listOf(summary(CONTACT, unreadCount = 2, connectedPeerID = BOB))
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        // Unread first, as upstream sorts them.
        assertEquals(
            listOf(listOf(BOB to 2, ALICE to 0)),
            peerRows().map { rows -> rows.map { it["peerID"] to it["unreadCount"] } }
        )
    }

    @Test
    fun `openLatestUnreadPrivateChat answers the conversation upstream picks and withdraws its sheet request`() {
        // Upstream picks the latest unread chat and asks its UI to show it (showPrivateChatSheet).
        doAnswer {
            privateChatSheetPeer.value = CONTACT
            null
        }.whenever(viewModel).openLatestUnreadPrivateChat()
        doAnswer {
            privateChatSheetPeer.value = null
            null
        }.whenever(viewModel).hidePrivateChatSheet()
        val result = RecordingResult()

        val claimed = bridge.handle(MethodCall(ChatBridge.METHOD_OPEN_LATEST_UNREAD_PRIVATE_CHAT, null), result)

        assertTrue(claimed)
        verify(viewModel).openLatestUnreadPrivateChat()
        assertEquals(listOf("success:$CONTACT"), result.calls)
        assertEquals("Flutter has no sheet; the request is handed to Dart once", null, privateChatSheetPeer.value)
        // Dart opens its private chat screen, which starts the chat like any other.
        verifyBlocking(viewModel, never()) { startPrivateChat(any()) }
    }

    @Test
    fun `with nothing unread openLatestUnreadPrivateChat answers null`() {
        val result = RecordingResult()

        bridge.handle(MethodCall(ChatBridge.METHOD_OPEN_LATEST_UNREAD_PRIVATE_CHAT, null), result)

        verify(viewModel).openLatestUnreadPrivateChat()
        assertEquals(listOf("success:null"), result.calls)
    }

    @Test
    fun `a sheet request left by someone else is never taken for the answer`() {
        // Upstream's other writers of the request (e.g. geohash DMs) answer to no one here.
        privateChatSheetPeer.value = "nostr_stale"
        doAnswer {
            privateChatSheetPeer.value = null
            null
        }.whenever(viewModel).hidePrivateChatSheet()
        val result = RecordingResult()

        // Nothing unread: upstream returns without asking for a sheet.
        bridge.handle(MethodCall(ChatBridge.METHOD_OPEN_LATEST_UNREAD_PRIVATE_CHAT, null), result)

        assertEquals(listOf("success:null"), result.calls)
    }

    // --- notification taps (#57) --------------------------------------------------------------

    @Test
    fun `takePendingNavigation hands Dart the tapped notification's destination once`() {
        pendingNavigation.offer(ChatNavigation.PrivateChat(ALICE, "alice"))
        val first = RecordingResult()
        val second = RecordingResult()

        val claimed = bridge.handle(MethodCall(ChatBridge.METHOD_TAKE_PENDING_NAVIGATION, null), first)
        bridge.handle(MethodCall(ChatBridge.METHOD_TAKE_PENDING_NAVIGATION, null), second)

        assertTrue(claimed)
        assertEquals(
            listOf(mapOf("target" to "privateChat", "peerID" to ALICE, "senderNickname" to "alice")),
            first.values
        )
        assertEquals(listOf("success:null"), second.calls)
        assertEquals(null, pendingNavigation.pending.value)
    }

    @Test
    fun `taking the destination opens nothing upstream by itself`() {
        // Dart opens its private chat screen, which starts the chat like any other.
        pendingNavigation.offer(ChatNavigation.PrivateChat(ALICE, "alice"))

        bridge.handle(MethodCall(ChatBridge.METHOD_TAKE_PENDING_NAVIGATION, null), RecordingResult())

        verifyBlocking(viewModel, never()) { startPrivateChat(any()) }
        verify(viewModel, never()).endPrivateChat()
    }

    @Test
    fun `Dart subscribing learns of a tap that came before the engine`() {
        // Cold start: the Activity reads the notification before Dart runs.
        pendingNavigation.offer(ChatNavigation.PublicChat)

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(mapOf("target" to "publicChat")), pendingNavigations())
    }

    @Test
    fun `a tap while running is pushed after the debounce, and its taking too`() {
        settleAndClear()

        pendingNavigation.offer(ChatNavigation.PrivateChat(ALICE, null))
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        bridge.handle(MethodCall(ChatBridge.METHOD_TAKE_PENDING_NAVIGATION, null), RecordingResult())
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(
            listOf(mapOf("target" to "privateChat", "peerID" to ALICE, "senderNickname" to null), null),
            pendingNavigations()
        )
    }

    @Test
    fun `requestSnapshot pushes the pending destination`() {
        settleAndClear()
        pendingNavigation.offer(ChatNavigation.PublicChat)

        bridge.handle(MethodCall(ChatBridge.METHOD_REQUEST_SNAPSHOT, null), RecordingResult())
        poster.runAll()

        assertEquals(listOf(mapOf("target" to "publicChat")), pendingNavigations())
    }

    // --- favourites (#58) ----------------------------------------------------------------------

    @Test
    fun `toggleFavorite hands the ID to upstream's toggle and answers once it ran`() {
        // The ID is the one the row or the private chat carries: a mesh peer ID, an offline
        // favourite's Noise key, or the contact_ conversation upstream has in focus.
        listOf(ALICE, NOISE_DORA, CONTACT).forEach { id ->
            val result = RecordingResult()

            val claimed = bridge.handle(toggleFavoriteCall(id), result)

            assertTrue(claimed)
            verify(viewModel).toggleFavorite(id)
            assertEquals(listOf("success:null"), result.calls)
        }
    }

    @Test
    fun `toggleFavorite without a peer ID is rejected`() {
        listOf(
            MethodCall(ChatBridge.METHOD_TOGGLE_FAVORITE, null),
            MethodCall(ChatBridge.METHOD_TOGGLE_FAVORITE, mapOf("peerID" to "")),
            MethodCall(ChatBridge.METHOD_TOGGLE_FAVORITE, mapOf("peerID" to 7)),
            MethodCall(ChatBridge.METHOD_TOGGLE_FAVORITE, ALICE)
        ).forEach { call ->
            val result = RecordingResult()

            bridge.handle(call, result)

            assertEquals(listOf("error:INVALID_ARGUMENT"), result.calls)
        }
        verify(viewModel, never()).toggleFavorite(any())
    }

    @Test
    fun `a favourite upstream toggles is pushed with the peer's row and the open private chat`() {
        connectedPeers.value = listOf(ALICE)
        peerNicknames.value = mapOf(ALICE to "alice")
        peerFingerprints.value = mapOf(ALICE to FP_ALICE)
        contacts[CONTACT] = ChatPrivateChat.Contact(CONTACT, meshPeerID = ALICE, displayName = "alice", favoriteNickname = null)
        selectedPrivateChatPeer.value = CONTACT
        settleAndClear()

        // What PrivateChatManager.toggleFavorite does to upstream state.
        favoritePeers.value = setOf(FP_ALICE)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(listOf(ALICE to true)), peerRows().map { rows -> rows.map { it["peerID"] to it["isFavorite"] } })
        assertEquals(listOf(true to false), focusEvents().map { it["isFavorite"] to it["theyFavoritedUs"] })
    }

    @Test
    fun `a peer telling us it favourited us is pushed too`() {
        connectedPeers.value = listOf(ALICE)
        peerFingerprints.value = mapOf(ALICE to FP_ALICE)
        settleAndClear()

        // MessageHandler records it in the favourites store; ChatViewModel's listener then
        // refreshes peerFavoritedUs.
        peerFavoritedUs.value = setOf(FP_ALICE)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(listOf(false to true)), peerRows().map { rows -> rows.map { it["isFavorite"] to it["theyFavoritedUs"] } })
    }

    @Test
    fun `the private chat star falls back to upstream's by-ID lookups`() {
        // No fingerprint known for the chat: upstream asks isFavorite(peerID) and the favourites store.
        whenever(viewModel.isFavorite(ALICE)).thenReturn(true)
        records.theyFavoritedUsIDs += ALICE
        selectedPrivateChatPeer.value = ALICE

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(true to true), focusEvents().map { it["isFavorite"] to it["theyFavoritedUs"] })
    }

    @Test
    fun `offline favourites from upstream's store are listed after the connected peers`() {
        connectedPeers.value = listOf(ALICE)
        peerNicknames.value = mapOf(ALICE to "alice")
        records.favorites += favorite(NOISE_DORA, "dora")
        records.favorites += favorite(NOISE_ALICE, "alice")
        whenever(viewModel.getMeshPeerInfo(ALICE)).thenReturn(peerInfo(ALICE, isDirect = true, noiseKeyHex = NOISE_ALICE))

        events.onListen(null, sink)
        poster.runAll()

        // Alice's record is her connected row; Dora is offline, keyed by her Noise key.
        assertEquals(
            listOf(listOf(ALICE to "bluetooth", NOISE_DORA to "offline")),
            peerRows().map { rows -> rows.map { it["peerID"] to it["connection"] } }
        )
        assertEquals("the online count is still the mesh's", listOf(1), peerEvents().map { it["onlineCount"] })
    }

    @Test
    fun `a connected peer's cached Noise key also matches its favourite record`() {
        connectedPeers.value = listOf(ALICE)
        records.favorites += favorite(NOISE_ALICE, "alice")
        records.cachedNoiseKeys[ALICE] = NOISE_ALICE

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(listOf(ALICE)), peerRows().map { rows -> rows.map { it["peerID"] } })
    }

    @Test
    fun `a change in upstream's favourites store is pushed`() {
        settleAndClear()

        // E.g. an offline favourite toggled off: toggleFavorite rewrites its record.
        records.favorites += favorite(NOISE_DORA, "dora")
        records.notifyFavoritesChanged()
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(listOf(NOISE_DORA)), peerRows().map { rows -> rows.map { it["peerID"] } })
    }

    @Test
    fun `the favourites store listener goes with the engine`() {
        assertTrue(records.hasListener)

        bridge.destroy()

        assertFalse(records.hasListener)
    }

    // --- blocking (#58) -----------------------------------------------------------------------

    @Test
    fun `a blocked peer's public and private messages are not projected`() {
        records.blocked += MALLORY
        records.blocked += MALLORY_CONTACT
        messages.value = listOf(message("A1", senderPeerID = ALICE), message("M1", senderPeerID = MALLORY))
        privateChats.value = mapOf(
            MALLORY_CONTACT to listOf(message("PM", senderPeerID = MALLORY), privateMessage("MINE", DeliveryStatus.Sent)),
            CONTACT to listOf(message("PA", senderPeerID = ALICE))
        )

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(listOf("A1")), publicTimelineIds())
        assertEquals(listOf(mapOf(MALLORY_CONTACT to listOf("MINE"), CONTACT to listOf("PA"))), privateChatIds())
    }

    @Test
    fun `a blocked peer's unread conversation is not projected as unread`() {
        records.blocked += MALLORY_CONTACT
        connectedPeers.value = listOf(MALLORY)
        unreadPrivateMessages.value = setOf(MALLORY_CONTACT)
        conversations.value = listOf(summary(MALLORY_CONTACT, unreadCount = 3, connectedPeerID = MALLORY))

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(false to emptyMap<String, Int>()), unreadEvents().map { it["hasUnread"] to it["conversations"] })
        assertEquals(listOf(listOf(MALLORY to 0)), peerRows().map { rows -> rows.map { it["peerID"] to it["unreadCount"] } })
    }

    @Test
    fun `block and unblock commands are re-projected once upstream ran them`() {
        acceptSends(true)
        messages.value = listOf(message("M1", senderPeerID = MALLORY))
        privateChats.value = mapOf(MALLORY_CONTACT to listOf(message("PM", senderPeerID = MALLORY)))
        settleAndClear()

        // CommandProcessor's /block adds the fingerprint to DataManager, outside any flow.
        doAnswer { invocation ->
            records.blocked += setOf(MALLORY, MALLORY_CONTACT)
            @Suppress("UNCHECKED_CAST")
            (invocation.arguments[1] as (Boolean) -> Unit).invoke(true)
            null
        }.whenever(viewModel).sendMessage(eq("/block mallory"), any())
        bridge.handle(sendCall("/block mallory"), RecordingResult())
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(emptyList<Any?>()), publicTimelineIds())
        assertEquals(listOf(mapOf(MALLORY_CONTACT to emptyList<Any?>())), privateChatIds())
        sink.events.clear()

        // /unblock: everything the peer sent shows again, as it is still in upstream's store.
        doAnswer { invocation ->
            records.blocked.clear()
            @Suppress("UNCHECKED_CAST")
            (invocation.arguments[1] as (Boolean) -> Unit).invoke(true)
            null
        }.whenever(viewModel).sendMessage(eq("/unblock mallory"), any())
        bridge.handle(sendCall("/unblock mallory"), RecordingResult())
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(listOf("M1")), publicTimelineIds())
        assertEquals(listOf(mapOf(MALLORY_CONTACT to listOf("PM"))), privateChatIds())
    }

    @Test
    fun `while nobody is blocked no sender is looked up`() {
        messages.value = List(3) { i -> message("A$i", senderPeerID = ALICE) }
        privateChats.value = mapOf(CONTACT to listOf(message("PA", senderPeerID = ALICE)))

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(emptyList<String>(), records.blockLookups)
    }

    // --- snapshot projection -----------------------------------------------------------------

    @Test
    fun `a timeline upstream cleared is pushed as empty`() {
        // What `/clear` does to ChatState.messages, the list the native mesh timeline shows too.
        messages.value = listOf(message("A"), message("B"))
        settleAndClear()

        messages.value = emptyList()
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(emptyList<Any?>()), publicTimelineIds())
    }

    @Test
    fun `requestSnapshot pushes the current public timeline`() {
        events.onListen(null, sink)
        poster.runAll()
        sink.events.clear()
        messages.value = listOf(message("A", sender = "alice"))
        val result = RecordingResult()

        val claimed = bridge.handle(MethodCall(ChatBridge.METHOD_REQUEST_SNAPSHOT, null), result)
        poster.runAll()

        assertTrue(claimed)
        assertEquals(listOf("success:null"), result.calls)
        assertEquals(listOf(listOf("A")), publicTimelineIds())
    }

    @Test
    fun `Dart subscribing receives the current public timeline`() {
        messages.value = listOf(message("A"), message("B"))

        events.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(listOf("A", "B")), publicTimelineIds())
    }

    @Test
    fun `timeline changes are pushed once, after the debounce`() {
        events.onListen(null, sink)
        poster.runAll()
        sink.events.clear()

        dispatcher.scheduler.runCurrent()
        messages.value = listOf(message("A"))
        dispatcher.scheduler.advanceTimeBy(ChatBridge.SNAPSHOT_DEBOUNCE_MS / 2)
        messages.value = listOf(message("A"), message("B"))
        dispatcher.scheduler.advanceTimeBy(ChatBridge.SNAPSHOT_DEBOUNCE_MS / 2)
        dispatcher.scheduler.runCurrent()
        poster.runAll()
        assertEquals("still inside the debounce window", emptyList<List<Any?>>(), publicTimelineIds())

        dispatcher.scheduler.advanceTimeBy(ChatBridge.SNAPSHOT_DEBOUNCE_MS)
        dispatcher.scheduler.runCurrent()
        poster.runAll()

        assertEquals(listOf(listOf("A", "B")), publicTimelineIds())
    }

    @Test
    fun `nickname change re-evaluates which messages are our own`() {
        nickname.value = "old"
        messages.value = listOf(message("A", sender = "new", senderPeerID = "ffffffffffffffff"))
        events.onListen(null, sink)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        sink.events.clear()

        nickname.value = "new"
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(listOf(listOf(true)), publicTimeline().map { list -> list.map { it["isFromSelf"] } })
    }

    @Test
    fun `destroy cancels the engine-scoped work`() {
        bridge.destroy()

        assertFalse(scope.isActive)
    }

    @Test
    fun `nothing is projected after destroy`() {
        events.onListen(null, sink)
        poster.runAll()
        sink.events.clear()

        bridge.destroy()
        messages.value = listOf(message("A"))
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()

        assertEquals(emptyList<Any?>(), sink.events)
    }

    @Test
    fun `an engine going away ends the private chat its screen had open`() {
        // The private chat screen goes with the engine and Dart restarts at its first screen, so
        // nobody is looking at that chat any more. Left selected, upstream would count it as open:
        // read receipts for it once the app is back in front, and no notifications (#56).
        selectedPrivateChatPeer.value = CONTACT

        bridge.destroy()

        verify(viewModel).endPrivateChat()
    }

    @Test
    fun `an engine going away with no private chat open leaves upstream alone`() {
        bridge.destroy()

        verify(viewModel, never()).endPrivateChat()
    }

    // --- helpers -----------------------------------------------------------------------------

    /** The public composer sends without `privateChat`; the private one names its chat. */
    private fun sendCall(text: String, privateChat: String? = null) = MethodCall(
        ChatBridge.METHOD_SEND_MESSAGE,
        if (privateChat == null) mapOf("text" to text) else mapOf("text" to text, "privateChat" to privateChat)
    )

    private fun setNicknameCall(nickname: String) =
        MethodCall(ChatBridge.METHOD_SET_NICKNAME, mapOf("nickname" to nickname))

    private fun updateInputCall(text: String, privateChat: String? = null) = MethodCall(
        ChatBridge.METHOD_UPDATE_INPUT,
        mapOf("text" to text, "privateChat" to privateChat)
    )

    private fun startPrivateChatCall(peerID: String) =
        MethodCall(ChatBridge.METHOD_START_PRIVATE_CHAT, mapOf("peerID" to peerID))

    private fun toggleFavoriteCall(peerID: String) =
        MethodCall(ChatBridge.METHOD_TOGGLE_FAVORITE, mapOf("peerID" to peerID))

    /** One of our favourites as upstream's favourites store records it. */
    private fun favorite(noiseKeyHex: String, nickname: String) = ChatFavorites.Favorite(
        noiseKeyHex = noiseKeyHex,
        nostrPubkeyHex = null,
        nickname = nickname,
        theyFavoritedUs = false,
        conversationID = "contact_" + noiseKeyHex.reversed()
    )

    private fun selectCommandCall(command: String) =
        MethodCall(ChatBridge.METHOD_SELECT_COMMAND_SUGGESTION, mapOf("command" to command))

    private fun selectMentionCall(nickname: String, currentText: String) = MethodCall(
        ChatBridge.METHOD_SELECT_MENTION_SUGGESTION,
        mapOf("nickname" to nickname, "currentText" to currentText)
    )

    /** Upstream's endPrivateChat clears the selection (`PrivateChatManager.endPrivateChat`). */
    private fun endClearsFocus() {
        doAnswer {
            selectedPrivateChatPeer.value = null
            null
        }.whenever(viewModel).endPrivateChat()
    }

    private fun acceptSends(accepted: Boolean) {
        doAnswer { invocation ->
            @Suppress("UNCHECKED_CAST")
            (invocation.arguments[1] as (Boolean) -> Unit).invoke(accepted)
            null
        }.whenever(viewModel).sendMessage(any(), any())
    }

    private fun message(
        id: String,
        sender: String = "alice",
        senderPeerID: String? = "1122334455667788"
    ) = BitchatMessage(
        id = id,
        sender = sender,
        content = "content of $id",
        timestamp = Date(1_700_000_000_000L),
        senderPeerID = senderPeerID
    )

    /** One of our own private messages, as upstream holds it while it is being delivered. */
    private fun privateMessage(id: String, status: DeliveryStatus) = BitchatMessage(
        id = id,
        sender = "me",
        content = "content of $id",
        timestamp = Date(1_700_000_000_000L),
        isPrivate = true,
        senderPeerID = MY_PEER_ID,
        deliveryStatus = status
    )

    /** A row of upstream's conversation list (`ChatViewModel.conversations`). */
    private fun summary(conversationID: String, unreadCount: Int, connectedPeerID: String?) = ConversationSummary(
        conversationID = conversationID,
        displayName = "alice",
        unreadCount = unreadCount,
        latestMessageAt = 1_700_000_000_000L,
        latestActivityOrder = 1L,
        latestMessageType = BitchatMessageType.Message,
        latestMessagePreview = "hi",
        transport = DirectMessageTransport.MESH,
        nostrPubkey = null,
        identityAliases = setOf(conversationID),
        isConnected = connectedPeerID != null,
        connectedPeerID = connectedPeerID
    )

    /** The delivery status of the first message of the first conversation, per private chats snapshot. */
    @Suppress("UNCHECKED_CAST")
    private fun privateChatStatuses(): List<Any?> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_PRIVATE_CHATS }
        .map { event -> (event["chats"] as Map<String, List<Map<String, Any?>>>).values.first().first()["deliveryStatus"] }

    private fun privateChatStatusKinds(): List<Any?> = privateChatStatuses().map { (it as Map<*, *>)["kind"] }

    @Suppress("UNCHECKED_CAST")
    private fun unreadEvents(): List<Map<String, Any?>> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_UNREAD }

    @Suppress("UNCHECKED_CAST")
    private fun publicTimeline(): List<List<Map<String, Any?>>> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_PUBLIC_MESSAGES }
        .map { it["messages"] as List<Map<String, Any?>> }

    private fun publicTimelineIds() = publicTimeline().map { list -> list.map { it["id"] } }

    @Suppress("UNCHECKED_CAST")
    private fun nicknames(): List<Any?> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_NICKNAME }
        .map { it["nickname"] }

    @Suppress("UNCHECKED_CAST")
    private fun peerEvents(): List<Map<String, Any?>> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_PEERS }

    @Suppress("UNCHECKED_CAST")
    private fun peerRows(): List<List<Map<String, Any?>>> =
        peerEvents().map { it["peers"] as List<Map<String, Any?>> }

    /** Each pushed peer snapshot as (onlineCount, peer IDs in list order). */
    private fun peerSnapshots(): List<Pair<Any?, List<Any?>>> =
        peerEvents().zip(peerRows()) { event, rows -> event["onlineCount"] to rows.map { it["peerID"] } }

    @Suppress("UNCHECKED_CAST")
    private fun suggestionEvents(): List<Map<String, Any?>> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_SUGGESTIONS }

    @Suppress("UNCHECKED_CAST")
    private fun suggestionCommands(): List<List<Any?>> =
        suggestionEvents().map { event -> (event["commands"] as List<Map<String, Any?>>).map { it["command"] } }

    @Suppress("UNCHECKED_CAST")
    private fun focusEvents(): List<Map<String, Any?>> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_SELECTED_PRIVATE_PEER }

    private fun focusPeerIDs(): List<Any?> = focusEvents().map { it["peerID"] }

    /** Each pushed private chats snapshot as conversation key → message IDs. */
    @Suppress("UNCHECKED_CAST")
    private fun privateChatIds(): List<Map<String, List<Any?>>> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_PRIVATE_CHATS }
        .map { event ->
            (event["chats"] as Map<String, List<Map<String, Any?>>>).mapValues { (_, list) -> list.map { it["id"] } }
        }

    /** The `navigation` of every pushed pending navigation snapshot. */
    @Suppress("UNCHECKED_CAST")
    private fun pendingNavigations(): List<Any?> = sink.events
        .map { it as Map<String, Any?> }
        .filter { it["type"] == ChatSerialization.EVENT_PENDING_NAVIGATION }
        .map { it["navigation"] }

    /** Subscribes, lets the initial projections run, and forgets what they pushed. */
    private fun settleAndClear() {
        events.onListen(null, sink)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        sink.events.clear()
    }

    private fun peerInfo(id: String, isDirect: Boolean, noiseKeyHex: String? = null) = PeerInfo(
        id = id,
        nickname = "",
        isConnected = true,
        isDirectConnection = isDirect,
        noisePublicKey = noiseKeyHex?.chunked(2)?.map { it.toInt(16).toByte() }?.toByteArray(),
        signingPublicKey = null,
        isVerifiedNickname = false,
        lastSeen = 0L
    )

    /** In-memory stand-in for upstream's favourites store and block list. */
    private class FakeRecords : ChatRecords {
        val favorites = mutableListOf<ChatFavorites.Favorite>()
        val theyFavoritedUsIDs = mutableSetOf<String>()
        val nostrKeys = mutableMapOf<String, String>()
        val cachedNoiseKeys = mutableMapOf<String, String>()
        val blocked = mutableSetOf<String>()
        val blockLookups = mutableListOf<String>()
        private var listener: (() -> Unit)? = null

        val hasListener: Boolean get() = listener != null

        fun notifyFavoritesChanged() = listener?.invoke()

        override fun ourFavorites() = favorites.toList()
        override fun theyFavoritedUs(peerID: String) = peerID in theyFavoritedUsIDs
        override fun nostrPubkeyHex(peerID: String) = nostrKeys[peerID]
        override fun cachedNoiseKeyHex(peerID: String) = cachedNoiseKeys[peerID]
        override fun addFavoritesListener(onChange: () -> Unit): () -> Unit {
            listener = onChange
            return { listener = null }
        }
        override fun hasBlockedPeers() = blocked.isNotEmpty()
        override fun isPeerBlocked(peerID: String): Boolean {
            blockLookups += peerID
            return peerID in blocked
        }
    }

    private companion object {
        const val MY_PEER_ID = "a1b2c3d4e5f60718"
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        const val MALLORY = "6666666666666666"
        val CONTACT = "contact_" + "a".repeat(64)
        val MALLORY_CONTACT = "contact_" + "6".repeat(64)
        val FP_ALICE = "f".repeat(64)
        val NOISE_ALICE = "a".repeat(63) + "1"
        val NOISE_DORA = "d".repeat(63) + "1"
        val CLEAR = CommandSuggestion("/clear", emptyList(), null, "clear chat messages")
    }
}
