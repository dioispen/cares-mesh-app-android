package com.bitchat.android.flutter

import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.ui.ChatViewModel
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
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
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
    private val viewModel = mock<ChatViewModel>().also { vm ->
        whenever(vm.messages).thenReturn(messages)
        whenever(vm.nickname).thenReturn(nickname)
        whenever(vm.myPeerID).thenReturn(MY_PEER_ID)
    }
    private val bridge = ChatBridge(viewModel, events, scope)

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

    // --- snapshot projection -----------------------------------------------------------------

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

    private companion object {
        const val MY_PEER_ID = "a1b2c3d4e5f60718"
    }
}
