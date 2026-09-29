package com.bitchat.android.flutter

import android.util.Log
import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.wifiaware.WifiAwareController
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
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
 * Private chats (#55) follow the same rule: which conversation the composer's text goes to is
 * `ChatViewModel.selectedPrivateChatPeer`, changed only by upstream's own methods; Dart opens and
 * closes its private chat screen from the `chat_selected_private_peer` projection. The one check
 * the bridge adds is on sending: text is handed over only when the composer it came from is the one
 * upstream would route it to (see [sendMessage]), because Dart sees the focus a debounce late.
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
    private val wifiAwarePeers: StateFlow<Map<String, String>> = WifiAwareController.connectedPeers,
    /** Upstream's contact records for a private chat ID (`ContactDirectory`, favourites). */
    private val privateChatContact: (String) -> ChatPrivateChat.Contact = ChatPrivateChat::upstreamContact
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

    /** The latest private chat start or end; each one waits for the one before (see [endPrivateChat]). */
    private var privateChatAction: Job? = null

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
        ),
        // The private chat in focus, whoever set it (a Flutter start, `/m`, `/block`, deletion...),
        // plus what its title and conversation key are resolved against: upstream's private chat
        // screen re-resolves them as peers come, go and announce.
        Projection(
            changes = merge(
                chatViewModel.selectedPrivateChatPeer,
                chatViewModel.peerNicknames,
                chatViewModel.connectedPeers
            ),
            snapshot = { ChatSerialization.selectedPrivatePeerEvent(currentPrivateChatFocus()) }
        ),
        // Nickname is part of the key for the same reason as the public timeline's.
        Projection(
            changes = combine(chatViewModel.privateChats, chatViewModel.nickname) { _, _ -> },
            snapshot = {
                ChatSerialization.privateChatsEvent(chatViewModel.privateChats.value, currentSelf())
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
            METHOD_START_PRIVATE_CHAT -> startPrivateChat(call, result)
            METHOD_END_PRIVATE_CHAT -> endPrivateChat(result)
            METHOD_REQUEST_SNAPSHOT -> {
                pushSnapshots()
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    /**
     * `chat_sendMessage({text, privateChat?})` → `ChatViewModel.sendMessage`, which routes it
     * (public, the selected private chat, or a `/` command). Answers whether upstream accepted it.
     * Like the upstream chat screen, the text is trimmed and blank text is never sent.
     *
     * `privateChat` names the composer the text was typed in: absent or null for the public chat,
     * the `chat_selected_private_peer` `peerID` for the private chat screen. It routes nothing —
     * upstream alone decides where text goes, by its `selectedPrivateChatPeer` at this moment. It
     * is a guard: text is only handed over when upstream's focus is that composer's, and otherwise
     * answered `false` (not sent, left in the composer). Dart follows the focus through a debounced
     * snapshot, so for a moment the two can disagree — right after `/m`, or after upstream ends a
     * private chat by itself — and without this check public text could leave as a private message,
     * or worse, private text be broadcast to the public timeline.
     */
    private fun sendMessage(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val text = arguments?.get("text") as? String
        val privateChat = arguments?.get("privateChat")
        if (text == null || (privateChat != null && privateChat !is String)) {
            result.error("INVALID_ARGUMENT", "$METHOD_SEND_MESSAGE expects {text: String, privateChat: String?}", null)
            return
        }
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            result.success(false)
            return
        }
        val focus = chatViewModel.selectedPrivateChatPeer.value
        if (focus != privateChat) {
            Log.w(TAG, "Not sending: composer is for ${privateChat ?: "the public chat"}, upstream focus is ${focus ?: "the public chat"}")
            result.success(false)
            return
        }
        chatViewModel.sendMessage(trimmed) { accepted -> result.success(accepted) }
    }

    /**
     * `chat_startPrivateChat({peerID})` → `ChatViewModel.startPrivateChat`, what upstream's private
     * chat screen runs when it opens (`PrivateChatSheet`'s `LaunchedEffect(peerID)`): it loads the
     * conversation's stored history, focuses it, clears its unread state, sends read receipts,
     * starts a Noise handshake if needed and tells the notifications which chat is open. Upstream
     * may pick a different ID (a peer with a known Noise key becomes its `contact_…` conversation)
     * or refuse (a blocked peer). Answers, once it is done, with the `chat_selected_private_peer`
     * map as it then stands, so Dart learns the outcome without waiting for the snapshot.
     */
    private fun startPrivateChat(call: MethodCall, result: MethodChannel.Result) {
        val peerID = (call.arguments as? Map<*, *>)?.get("peerID") as? String
        if (peerID.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "$METHOD_START_PRIVATE_CHAT expects {peerID: String}", null)
            return
        }
        val previous = privateChatAction
        privateChatAction = scope.launch {
            previous?.join()
            try {
                chatViewModel.startPrivateChat(peerID)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                result.error("PRIVATE_CHAT_FAILED", e.message, null)
                return@launch
            }
            result.success(ChatSerialization.selectedPrivatePeerEvent(currentPrivateChatFocus()))
        }
    }

    /**
     * `chat_endPrivateChat` → `ChatViewModel.endPrivateChat` (what closing upstream's private chat
     * screen runs), answered with the `chat_selected_private_peer` map as it then stands.
     *
     * Applied only after a `chat_startPrivateChat` still running: upstream's start selects the
     * peer at the end of its history load, so a user who leaves the screen right after opening it
     * would otherwise be left with that late selection — and the public composer's next text
     * routed privately. Private chat actions thus take effect in the order Flutter sent them.
     */
    private fun endPrivateChat(result: MethodChannel.Result) {
        val previous = privateChatAction
        privateChatAction = scope.launch {
            previous?.join()
            chatViewModel.endPrivateChat()
            result.success(ChatSerialization.selectedPrivatePeerEvent(currentPrivateChatFocus()))
        }
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
     * `chat_updateInput({text, privateChat?})`: what the native composer the text was typed in does
     * on every text change, with the text untouched. `privateChat` names that composer, as for
     * `chat_sendMessage`:
     * - the public composer (none): `ChatScreen`'s `onMessageTextChange` —
     *   `setConversationDraft(null, …)` (upstream keeps no draft for a null conversation), then
     *   `updateCommandSuggestions` and `updateMentionSuggestions`. The popups reach Dart through
     *   the `chat_suggestions` snapshot.
     * - a private chat's composer: `PrivateChatSheet`'s — only `setConversationDraft` for that
     *   chat. Upstream's private chat screen offers no `/` or `@` popups and leaves the shared
     *   suggestion state alone (an update would only leave a stale popup for the public composer);
     *   a `/` command typed there is still carried out when sent. The draft reaches Dart through
     *   the next `chat_selected_private_peer`.
     */
    private fun updateInput(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val text = arguments?.get("text") as? String
        val privateChat = arguments?.get("privateChat")
        if (text == null || (privateChat != null && privateChat !is String)) {
            result.error("INVALID_ARGUMENT", "$METHOD_UPDATE_INPUT expects {text: String, privateChat: String?}", null)
            return
        }
        chatViewModel.setConversationDraft(privateChat, text)
        if (privateChat == null) {
            chatViewModel.updateCommandSuggestions(text)
            chatViewModel.updateMentionSuggestions(text)
        }
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

    /** The private chat upstream has in focus, resolved as its private chat screen does; null if none. */
    private fun currentPrivateChatFocus(): ChatPrivateChat.Focus? {
        val peerID = chatViewModel.selectedPrivateChatPeer.value ?: return null
        val contact = privateChatContact(peerID)
        return ChatPrivateChat.Focus(
            peerID = peerID,
            conversationID = contact.conversationID,
            displayName = ChatPrivateChat.displayName(peerID, contact, chatViewModel.peerNicknames.value) {
                runCatching { chatViewModel.resolvePeerDisplayNameForFingerprint(peerID) }.getOrNull()
                    ?: peerID.take(8)
            },
            draft = runCatching { chatViewModel.conversationDraft(peerID) }.getOrNull().orEmpty()
        )
    }

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

        /** A composer's text changed: save its draft; the public one's also refreshes the popups. */
        const val METHOD_UPDATE_INPUT = "chat_updateInput"
        const val METHOD_SELECT_COMMAND_SUGGESTION = "chat_selectCommandSuggestion"
        const val METHOD_SELECT_MENTION_SUGGESTION = "chat_selectMentionSuggestion"

        /** Hide both popups; the native composer does this after a send clears the field. */
        const val METHOD_CLEAR_SUGGESTIONS = "chat_clearSuggestions"

        /** Open a private chat: `ChatViewModel.startPrivateChat`, answered with the resulting focus. */
        const val METHOD_START_PRIVATE_CHAT = "chat_startPrivateChat"

        /** Leave the private chat: `ChatViewModel.endPrivateChat`, answered with the (empty) focus. */
        const val METHOD_END_PRIVATE_CHAT = "chat_endPrivateChat"

        private const val TAG = "ChatBridge"

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
