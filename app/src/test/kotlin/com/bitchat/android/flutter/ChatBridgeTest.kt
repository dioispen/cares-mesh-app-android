package com.bitchat.android.flutter

import com.bitchat.android.mesh.PeerInfo
import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.ui.CommandSuggestion
import io.flutter.plugin.common.MethodCall
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
import org.mockito.kotlin.doAnswer
import org.mockito.kotlin.eq
import org.mockito.kotlin.inOrder
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.same
import org.mockito.kotlin.verify
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
    }
    private val bridge = ChatBridge(viewModel, events, scope, wifiAwarePeers)

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
            verify(viewModel).updateCommandSuggestions("/h")
            verify(viewModel).updateMentionSuggestions("/h")
        }
        assertEquals(listOf("success:null"), result.calls)
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

    // --- helpers -----------------------------------------------------------------------------

    private fun sendCall(text: String) = MethodCall(ChatBridge.METHOD_SEND_MESSAGE, mapOf("text" to text))

    private fun setNicknameCall(nickname: String) =
        MethodCall(ChatBridge.METHOD_SET_NICKNAME, mapOf("nickname" to nickname))

    private fun updateInputCall(text: String) = MethodCall(ChatBridge.METHOD_UPDATE_INPUT, mapOf("text" to text))

    private fun selectCommandCall(command: String) =
        MethodCall(ChatBridge.METHOD_SELECT_COMMAND_SUGGESTION, mapOf("command" to command))

    private fun selectMentionCall(nickname: String, currentText: String) = MethodCall(
        ChatBridge.METHOD_SELECT_MENTION_SUGGESTION,
        mapOf("nickname" to nickname, "currentText" to currentText)
    )

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

    /** Subscribes, lets the initial projections run, and forgets what they pushed. */
    private fun settleAndClear() {
        events.onListen(null, sink)
        dispatcher.scheduler.advanceUntilIdle()
        poster.runAll()
        sink.events.clear()
    }

    private fun peerInfo(id: String, isDirect: Boolean) = PeerInfo(
        id = id,
        nickname = "",
        isConnected = true,
        isDirectConnection = isDirect,
        noisePublicKey = null,
        signingPublicKey = null,
        isVerifiedNickname = false,
        lastSeen = 0L
    )

    private companion object {
        const val MY_PEER_ID = "a1b2c3d4e5f60718"
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        val CLEAR = CommandSuggestion("/clear", emptyList(), null, "clear chat messages")
    }
}
