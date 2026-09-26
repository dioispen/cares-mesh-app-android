package com.bitchat.android.flutter

import com.bitchat.android.ui.ChatViewModel
import io.flutter.plugin.common.MethodCall
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.mockito.kotlin.mock

class ChatBridgeTest {

    private val poster = ManualPoster()
    private val events = BridgeEventEmitter(postToMain = poster, logDropped = {})
    private val scope = CoroutineScope(Job())
    private val bridge = ChatBridge(mock<ChatViewModel>(), events, scope)

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
    fun `destroy cancels the engine-scoped work`() {
        bridge.destroy()

        assertFalse(scope.isActive)
    }
}
