package com.bitchat.android.flutter

import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.wifiaware.WifiAwareController
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.merge
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
 * whenever the upstream flows behind it change (most after [SNAPSHOT_DEBOUNCE_MS]; the composer's
 * suggestions after the much shorter [SUGGESTIONS_DEBOUNCE_MS]). Dart can always get the current
 * snapshots back — they are pushed when Dart (re)subscribes to the event channel, and on demand through
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
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    /** Peers linked over Wi-Fi Aware (peer ID → address), as the native peer list reads them. */
    private val wifiAwarePeers: StateFlow<Map<String, String>> = WifiAwareController.connectedPeers
) : BridgeMethodHandler {

    /**
     * One `chat_*` snapshot event: re-pushed [debounceMs] after [changes] last emitted, built from
     * current state.
     */
    private class Projection(
        val changes: Flow<*>,
        val debounceMs: Long = SNAPSHOT_DEBOUNCE_MS,
        val snapshot: () -> Map<String, Any?>
    )

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
        ),
        // Every flow the native list reads. Upstream refreshes nicknames, RSSI and directness
        // once a second and the peer set on every join/leave; the debounce folds a refresh that
        // touches several flows into one snapshot, read from all of them at once.
        Projection(
            changes = merge(
                chatViewModel.connectedPeers,
                chatViewModel.peerNicknames,
                chatViewModel.peerRSSI,
                chatViewModel.peerDirect,
                chatViewModel.privateChats,
                wifiAwarePeers
            ),
            snapshot = { ChatSerialization.peersEvent(currentPeerInputs(), ::isDirectOnMesh) }
        ),
        // The `/` and `@` popups follow every keystroke (chat_updateInput), so they get their own
        // short debounce; see SUGGESTIONS_DEBOUNCE_MS.
        Projection(
            changes = merge(
                chatViewModel.showCommandSuggestions,
                chatViewModel.commandSuggestions,
                chatViewModel.showMentionSuggestions,
                chatViewModel.mentionSuggestions
            ),
            debounceMs = SUGGESTIONS_DEBOUNCE_MS,
            snapshot = {
                ChatSerialization.suggestionsEvent(
                    showCommands = chatViewModel.showCommandSuggestions.value,
                    commands = chatViewModel.commandSuggestions.value,
                    showMentions = chatViewModel.showMentionSuggestions.value,
                    mentions = chatViewModel.mentionSuggestions.value
                )
            }
        )
    )

    init {
        projections.forEach { projection ->
            scope.launch {
                projection.changes
                    .debounce(projection.debounceMs)
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
            METHOD_UPDATE_INPUT -> updateInput(call, result)
            METHOD_SELECT_COMMAND_SUGGESTION -> selectCommandSuggestion(call, result)
            METHOD_SELECT_MENTION_SUGGESTION -> selectMentionSuggestion(call, result)
            METHOD_CLEAR_SUGGESTIONS -> {
                chatViewModel.clearSuggestions()
                result.success(null)
            }
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

    /**
     * `chat_updateInput({text})`: what the native composer does on every text change
     * (`ChatScreen` `onMessageTextChange`) — `updateCommandSuggestions` then
     * `updateMentionSuggestions`, with the text untouched. The resulting popups reach Dart through
     * the `chat_suggestions` snapshot. (Upstream also saves a draft there, but only for a private
     * conversation; the public chat has none.)
     */
    private fun updateInput(call: MethodCall, result: MethodChannel.Result) {
        val text = (call.arguments as? Map<*, *>)?.get("text") as? String
        if (text == null) {
            result.error("INVALID_ARGUMENT", "$METHOD_UPDATE_INPUT expects {text: String}", null)
            return
        }
        chatViewModel.updateCommandSuggestions(text)
        chatViewModel.updateMentionSuggestions(text)
        result.success(null)
    }

    /**
     * `chat_selectCommandSuggestion({command})` → the composer's new text from
     * `ChatViewModel.selectCommandSuggestion`, which also hides the popup. Dart names the
     * suggestion by its `command`; the upstream [com.bitchat.android.ui.CommandSuggestion] is
     * looked up in the list upstream is offering, never rebuilt from Dart's copy. A command no
     * longer offered (the list moved on) answers null and selects nothing.
     */
    private fun selectCommandSuggestion(call: MethodCall, result: MethodChannel.Result) {
        val command = (call.arguments as? Map<*, *>)?.get("command") as? String
        if (command == null) {
            result.error("INVALID_ARGUMENT", "$METHOD_SELECT_COMMAND_SUGGESTION expects {command: String}", null)
            return
        }
        val suggestion = chatViewModel.commandSuggestions.value.firstOrNull { it.command == command }
        result.success(suggestion?.let(chatViewModel::selectCommandSuggestion))
    }

    /**
     * `chat_selectMentionSuggestion({nickname, currentText})` → the composer's new text from
     * `ChatViewModel.selectMentionSuggestion`, which replaces the `@` fragment being typed and
     * hides the popup.
     */
    private fun selectMentionSuggestion(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val nickname = arguments?.get("nickname") as? String
        val currentText = arguments?.get("currentText") as? String
        if (nickname == null || currentText == null) {
            result.error(
                "INVALID_ARGUMENT",
                "$METHOD_SELECT_MENTION_SUGGESTION expects {nickname: String, currentText: String}",
                null
            )
            return
        }
        result.success(chatViewModel.selectMentionSuggestion(nickname, currentText))
    }

    private fun pushSnapshots() {
        if (!scope.isActive) return
        projections.forEach { events.emit(it.snapshot()) }
    }

    private fun currentSelf() = ChatSelf(
        peerID = chatViewModel.myPeerID,
        nickname = chatViewModel.nickname.value
    )

    private fun currentPeerInputs() = ChatPeerList.Inputs(
        myPeerID = chatViewModel.myPeerID,
        connectedPeers = chatViewModel.connectedPeers.value,
        peerNicknames = chatViewModel.peerNicknames.value,
        peerRSSI = chatViewModel.peerRSSI.value,
        peerDirect = chatViewModel.peerDirect.value,
        wifiAwarePeerIDs = wifiAwarePeers.value.keys,
        privateChats = chatViewModel.privateChats.value
    )

    /** `PeopleSection`'s fallback while `peerDirect` has not caught up with a new peer. */
    private fun isDirectOnMesh(peerID: String): Boolean =
        try {
            chatViewModel.getMeshPeerInfo(peerID)?.isDirectConnection == true
        } catch (_: Exception) {
            false
        }

    fun destroy() {
        scope.cancel()
    }

    companion object {
        const val METHOD_SEND_MESSAGE = "chat_sendMessage"
        const val METHOD_SET_NICKNAME = "chat_setNickname"

        /** One-shot read of `ChatViewModel.nickname`; UIs follow the `chat_nickname` snapshot. */
        const val METHOD_GET_NICKNAME = "chat_getNickname"
        const val METHOD_REQUEST_SNAPSHOT = "chat_requestSnapshot"

        /** The composer's text changed: refresh the `/` and `@` popups. */
        const val METHOD_UPDATE_INPUT = "chat_updateInput"
        const val METHOD_SELECT_COMMAND_SUGGESTION = "chat_selectCommandSuggestion"
        const val METHOD_SELECT_MENTION_SUGGESTION = "chat_selectMentionSuggestion"

        /** Hide both popups; the native composer does this after a send clears the field. */
        const val METHOD_CLEAR_SUGGESTIONS = "chat_clearSuggestions"

        /** Coalesces bursts (history sync, relayed floods) into one snapshot push. */
        const val SNAPSHOT_DEBOUNCE_MS = 100L

        /**
         * The popups answer typing, so 100 ms would be felt: with keys less than 100 ms apart the
         * list would not move until typing paused. One chat_updateInput writes up to four flows in
         * a row on the main thread; any positive debounce folds those into one snapshot, and one
         * frame (16 ms) does so without a visible delay.
         */
        const val SUGGESTIONS_DEBOUNCE_MS = 16L
    }
}
