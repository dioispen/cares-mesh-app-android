package com.bitchat.android.flutter

import com.bitchat.android.ui.ChatViewModel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Chat half of the Flutter bridge (#49).
 *
 * The upstream [ChatViewModel] stays the single source of truth for chat behaviour. This class
 * only projects its state to Flutter (`chat_*` typed events through the shared [events] emitter)
 * and forwards Flutter's chat actions to the ViewModel's existing methods; it holds no chat logic
 * of its own.
 *
 * Projection is snapshot-based: each [Projection] re-pushes its whole `chat_*` event, debounced,
 * whenever the upstream flows behind it change. Dart can always get the current snapshots back —
 * they are pushed when Dart (re)subscribes to the event channel, and on demand through
 * [METHOD_REQUEST_SNAPSHOT], which a Dart listener that joined the shared broadcast stream late
 * (and so never triggered `onListen`) uses to catch up.
 *
 * Methods are named `chat_<verb><Object>`; events `chat_<snake_case>`.
 *
 * It owns no channel. [BitchatFlutterChannels] registers the one method handler and the one
 * stream handler, and offers this bridge every method it does not recognise
 * (see [BridgeMethodDispatcher]).
 *
 * Lifetime is one Flutter engine: created in `FlutterChatActivity.configureFlutterEngine` and
 * [destroy]ed in `cleanUpFlutterEngine`. The ViewModel outlives it across Activity recreation, so
 * projection work runs in [scope] — never in `viewModelScope` — and stops with the engine.
 */
@OptIn(FlowPreview::class)
class ChatBridge(
    private val chatViewModel: ChatViewModel,
    private val events: BridgeEventEmitter,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
) : BridgeMethodHandler {

    /** One `chat_*` snapshot event: re-pushed when [changes] emits, built from current state. */
    private class Projection(val changes: Flow<*>, val snapshot: () -> Map<String, Any?>)

    private val projections = listOf(
        Projection(
            // Nickname is part of the key: it decides which messages count as our own.
            changes = combine(chatViewModel.messages, chatViewModel.nickname) { _, _ -> },
            snapshot = {
                ChatSerialization.publicMessagesEvent(chatViewModel.messages.value, currentSelf())
            }
        ),
        // Covers every writer, not just chat_setNickname (e.g. the panic reset to a new anonXXXX).
        Projection(
            changes = chatViewModel.nickname,
            snapshot = { ChatSerialization.nicknameEvent(chatViewModel.nickname.value) }
        )
    )

    init {
        projections.forEach { projection ->
            scope.launch {
                projection.changes
                    .debounce(SNAPSHOT_DEBOUNCE_MS)
                    .collect { events.emit(projection.snapshot()) }
            }
        }
        events.addOnListenCallback(::pushSnapshots)
    }

    override fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            METHOD_SEND_MESSAGE -> sendMessage(call, result)
            METHOD_SET_NICKNAME -> setNickname(call, result)
            METHOD_GET_NICKNAME -> result.success(chatViewModel.nickname.value)
            METHOD_REQUEST_SNAPSHOT -> {
                pushSnapshots()
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    /**
     * `chat_sendMessage({text})` → `ChatViewModel.sendMessage`, which routes it (public, the
     * selected private chat, or a `/` command). Answers whether upstream accepted it. Like the
     * upstream chat screen, the text is trimmed and blank text is never sent.
     */
    private fun sendMessage(call: MethodCall, result: MethodChannel.Result) {
        val text = (call.arguments as? Map<*, *>)?.get("text") as? String
        if (text == null) {
            result.error("INVALID_ARGUMENT", "$METHOD_SEND_MESSAGE expects {text: String}", null)
            return
        }
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            result.success(false)
            return
        }
        chatViewModel.sendMessage(trimmed) { accepted -> result.success(accepted) }
    }

    /**
     * `chat_setNickname({nickname})` → `ChatViewModel.setNickname`, which stores it and
     * re-announces on every transport. The nickname is passed exactly as given: upstream itself
     * neither trims nor rejects blank or long nicknames (its header editor saves every keystroke),
     * so the bridge adds no rule. The new value reaches Dart through the `chat_nickname` snapshot.
     */
    private fun setNickname(call: MethodCall, result: MethodChannel.Result) {
        val nickname = (call.arguments as? Map<*, *>)?.get("nickname") as? String
        if (nickname == null) {
            result.error("INVALID_ARGUMENT", "$METHOD_SET_NICKNAME expects {nickname: String}", null)
            return
        }
        chatViewModel.setNickname(nickname)
        result.success(null)
    }

    private fun pushSnapshots() {
        if (!scope.isActive) return
        projections.forEach { events.emit(it.snapshot()) }
    }

    private fun currentSelf() = ChatSelf(
        peerID = chatViewModel.myPeerID,
        nickname = chatViewModel.nickname.value
    )

    fun destroy() {
        scope.cancel()
    }

    companion object {
        const val METHOD_SEND_MESSAGE = "chat_sendMessage"
        const val METHOD_SET_NICKNAME = "chat_setNickname"

        /** One-shot read of `ChatViewModel.nickname`; UIs follow the `chat_nickname` snapshot. */
        const val METHOD_GET_NICKNAME = "chat_getNickname"
        const val METHOD_REQUEST_SNAPSHOT = "chat_requestSnapshot"

        /** Coalesces bursts (history sync, relayed floods) into one snapshot push. */
        const val SNAPSHOT_DEBOUNCE_MS = 100L
    }
}
