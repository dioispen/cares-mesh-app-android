package com.bitchat.android.flutter

import android.util.Log
import com.bitchat.android.services.ContactIdentityResolver
import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.wifiaware.WifiAwareController
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
 * Snapshots are built on [snapshotDispatcher], never on the main thread: building one reads
 * upstream's stored records — the identity store's cached Noise keys and the block list in
 * preferences ([ChatRecords]), and the identity store again inside upstream's own lookups
 * (`ContactDirectory`, `PrivateChatManager.isPeerBlocked`) — which touch disk and the keystore.
 * Only reads happen there; every call that changes upstream state stays on [scope]'s thread. Each
 * projection builds and emits its snapshots one at a time, in the order they were asked for, so an
 * older snapshot can never arrive after a newer one (see [Projection]).
 *
 * Methods are named `chat_<verb><Object>`; events `chat_<snake_case>`.
 *
 * Private chats (#55) follow the same rule: which conversation the composer's text goes to is
 * `ChatViewModel.selectedPrivateChatPeer`, changed only by upstream's own methods; Dart opens and
 * closes its private chat screen from the `chat_selected_private_peer` projection. The one check
 * the bridge adds is on sending: text is handed over only when the composer it came from is for the
 * chat upstream would route it to (see [sendMessage]), because Dart sees the focus a debounce late.
 *
 * Notification taps (#57) reach Dart the same way: the Activity leaves the tapped notification's
 * destination in [PendingChatNavigation], projected as `chat_pending_navigation`; Dart takes it with
 * [METHOD_TAKE_PENDING_NAVIGATION] once it can navigate and opens its screens as usual.
 *
 * Favourites and blocking (#58) are upstream's too: [METHOD_TOGGLE_FAVORITE] runs
 * `ChatViewModel.toggleFavorite`, and `/block` / `/unblock` are plain commands. Their state rides on
 * the existing snapshots — the stars and offline favourites on `chat_peers` and
 * `chat_selected_private_peer` ([ChatFavorites]), the blocked peers' messages left out of the
 * timelines and unread counts ([ChatBlocking]). Part of it lives outside `ChatViewModel`'s flows
 * ([ChatRecords]), so those snapshots are also re-pushed when the favourites store reports a change
 * and after every command upstream ran.
 *
 * Conversations (#73) are upstream's list too: `ChatViewModel.conversations`, projected as
 * `chat_conversations` ([ChatConversations]) for the conversations section above the people, which
 * lists every conversation upstream keeps — the peer offline and the chat read included. A row is
 * opened like any private chat, with its conversation ID through [METHOD_START_PRIVATE_CHAT]; a peer
 * with a listed conversation is left out of `chat_peers` as the native sheet leaves it out.
 *
 * Channels are not supported yet (P3): the bridge keeps upstream on the main timeline, refusing
 * the join command and leaving a channel upstream is already in ([ChatChannels]).
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
    /**
     * Where snapshots are built (see the class doc). One at a time: [UpstreamChatRecords] reads
     * through objects of its own that are not thread-safe.
     */
    private val snapshotDispatcher: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1),
    /** Peers linked over Wi-Fi Aware (peer ID → address), as the native peer list reads them. */
    private val wifiAwarePeers: StateFlow<Map<String, String>> = WifiAwareController.connectedPeers,
    /** The Activity's notification tap waiting for Dart (#57); it outlives this engine. */
    private val pendingNavigation: PendingChatNavigation = PendingChatNavigation(),
    /** Upstream's favourites store and block list (#58). */
    private val records: ChatRecords = UpstreamChatRecords(chatViewModel),
    /** Upstream's contact records for a private chat ID (`ContactDirectory`, favourites). */
    private val privateChatContact: (String) -> ChatPrivateChat.Contact = ChatPrivateChat::upstreamContact
) : BridgeMethodHandler {

    /**
     * One `chat_*` snapshot event: re-pushed [debounceMs] after [changes] last emitted, and at once
     * when a push is [requested]; [snapshot] builds it from current state.
     *
     * A single coroutine per projection takes both triggers in turn: it builds a snapshot, emits
     * it, and only then takes the next trigger (triggers that pile up meanwhile fold into one —
     * every snapshot reads the latest state anyway). So snapshots of one projection are emitted in
     * the order they were built, and each is built after the one before was emitted.
     */
    private class Projection(
        val changes: Flow<*>,
        val debounceMs: Long = SNAPSHOT_DEBOUNCE_MS,
        val snapshot: () -> Map<String, Any?>
    ) {
        private val pushRequests = Channel<Unit>(Channel.CONFLATED)

        /** Asks for a snapshot now, outside the debounce. Safe from any thread. */
        fun requestPush() {
            pushRequests.trySend(Unit)
        }

        val triggers: Flow<Any?> get() = merge(changes.debounce(debounceMs), pushRequests.receiveAsFlow()).conflate()
    }

    /** The latest private chat start or end; each one waits for the one before (see [endPrivateChat]). */
    private var privateChatAction: Job? = null

    /** Counts the favourites store's change reports (#58): offline favourites and stars read it. */
    private val favoritesChanged = MutableStateFlow(0L)

    /**
     * Counts the `/` commands upstream ran (#58). Its block list changes only through `/block` and
     * `/unblock`, inside `DataManager`, with no flow to follow; what it hides is re-projected after
     * every command instead.
     */
    private val commandsRun = MutableStateFlow(0L)

    /**
     * Everything a favourite star is resolved against (#58), for both the peer rows and the private
     * chat header: our favourites, theirs, the fingerprints they are keyed by, and the store.
     */
    private val favoriteStarChanges: Flow<*> = merge(
        chatViewModel.favoritePeers,
        chatViewModel.peerFavoritedUs,
        chatViewModel.peerFingerprints,
        favoritesChanged
    )

    /** What upstream's star asks by ID while a peer's fingerprint is unknown (#58). */
    private val favoriteFallbacks = ChatFavorites.Fallbacks(
        isFavorite = { id -> runCatching { chatViewModel.isFavorite(id) }.getOrDefault(false) },
        theyFavoritedUs = records::theyFavoritedUs
    )

    private val projections = listOf(
        Projection(
            // Nickname is part of the key: it decides which messages count as our own.
            changes = merge(combine(chatViewModel.messages, chatViewModel.nickname) { _, _ -> }, commandsRun),
            snapshot = {
                ChatSerialization.publicMessagesEvent(chatViewModel.messages.value, currentSelf(), blockedPeers())
            }
        ),
        // Covers every writer, not just chat_setNickname (e.g. the panic reset to a new anonXXXX).
        Projection(
            changes = chatViewModel.nickname,
            snapshot = { ChatSerialization.nicknameEvent(chatViewModel.nickname.value) }
        ),
        // Every flow the native list reads. Upstream refreshes nicknames, RSSI, directness and
        // fingerprints once a second and the peer set on every join/leave; the debounce folds a
        // refresh that touches several flows into one snapshot, read from all of them at once.
        // Offline favourites come from the favourites store; unread badges hide blocked peers.
        // `conversations` also decides who is left to the conversations section (#73).
        Projection(
            changes = merge(
                chatViewModel.connectedPeers,
                chatViewModel.peerNicknames,
                chatViewModel.peerRSSI,
                chatViewModel.peerDirect,
                chatViewModel.privateChats,
                chatViewModel.conversations,
                wifiAwarePeers,
                favoriteStarChanges,
                commandsRun
            ),
            snapshot = {
                ChatSerialization.peersEvent(currentPeerInputs(blockedPeers()), favoriteFallbacks, ::isDirectOnMesh)
            }
        ),
        // The `/` and `@` popups follow every keystroke (chat_updateInput), so they get their own
        // short debounce; see SUGGESTIONS_DEBOUNCE_MS. Never the join command (ChatChannels); Dart
        // hides the list when that leaves it empty.
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
                    commands = chatViewModel.commandSuggestions.value.filter(ChatChannels::isOffered),
                    showMentions = chatViewModel.showMentionSuggestions.value,
                    mentions = chatViewModel.mentionSuggestions.value
                )
            }
        ),
        // The private chat in focus, whoever set it (a Flutter start, `/m`, `/block`, deletion...),
        // plus what its title, conversation key and header star are resolved against: upstream's
        // private chat screen re-resolves them as peers come, go, announce and (un)favourite.
        Projection(
            changes = merge(
                chatViewModel.selectedPrivateChatPeer,
                chatViewModel.peerNicknames,
                chatViewModel.connectedPeers,
                favoriteStarChanges
            ),
            snapshot = ::privateChatFocusEvent
        ),
        // Nickname is part of the key for the same reason as the public timeline's. Delivery
        // status changes arrive here too: upstream replaces the message with a copy carrying the
        // new status (BitchatMessage equality includes it), so the flow emits.
        Projection(
            changes = merge(combine(chatViewModel.privateChats, chatViewModel.nickname) { _, _ -> }, commandsRun),
            snapshot = {
                ChatSerialization.privateChatsEvent(chatViewModel.privateChats.value, currentSelf(), blockedPeers())
            }
        ),
        // Unread marks and counts (#56). `conversations` is upstream's derived list and settles a
        // moment after the unread set; the debounce usually folds both into one snapshot.
        Projection(
            changes = merge(chatViewModel.unreadPrivateMessages, chatViewModel.conversations, commandsRun),
            snapshot = {
                val blocked = blockedPeers()
                ChatSerialization.unreadEvent(
                    ChatBlocking.visibleUnread(chatViewModel.unreadPrivateMessages.value, blocked),
                    ChatBlocking.visibleConversations(ChatUnread.conversations(chatViewModel.conversations.value), blocked)
                )
            }
        ),
        // The native sheet's conversations section (#73). `conversations` carries the names,
        // previews, unread counts and presence (upstream rebuilds it as messages, peers and the
        // unread set change); the transport icon and the star read the flows behind them, and
        // blocked peers are left out (re-checked after every command).
        Projection(
            changes = merge(
                chatViewModel.conversations,
                chatViewModel.conversationStoreState,
                chatViewModel.peerDirect,
                wifiAwarePeers,
                favoriteStarChanges,
                commandsRun
            ),
            snapshot = ::conversationsEvent
        ),
        // A tapped notification Dart has yet to act on (#57). On a cold start it is there before
        // Dart runs; Dart's subscription (or chat_requestSnapshot) picks it up.
        Projection(
            changes = pendingNavigation.pending,
            snapshot = { ChatSerialization.pendingNavigationEvent(pendingNavigation.pending.value) }
        )
    )

    /** Stops [favoritesChanged] following the favourites store; run when the engine goes. */
    private val removeFavoritesListener: () -> Unit

    init {
        projections.forEach { projection ->
            scope.launch {
                projection.triggers.collect { events.emit(buildSnapshot(projection.snapshot)) }
            }
        }
        events.addOnListenCallback(::pushSnapshots)
        // The store reports from whichever thread changed it; the counter is thread-safe and the
        // projections collect it on [scope].
        removeFavoritesListener = records.addFavoritesListener { favoritesChanged.update { it + 1 } }
        leaveChannels()
    }

    /**
     * Keeps upstream on the main timeline (see [ChatChannels]): whenever it is in a channel — when
     * this bridge starts, or later — and no private chat is in focus, it leaves the channel view as
     * upstream's own back navigation does (`switchToChannel(null)`; a private chat is left first
     * there too, and its focus would be cleared by it). Joined channels and their messages stay.
     */
    private fun leaveChannels() {
        scope.launch {
            combine(chatViewModel.currentChannel, chatViewModel.selectedPrivateChatPeer) { channel, privateChat ->
                channel != null && privateChat == null
            }.collect { inChannelView ->
                if (inChannelView) chatViewModel.switchToChannel(null)
            }
        }
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
            METHOD_OPEN_LATEST_UNREAD_PRIVATE_CHAT -> openLatestUnreadPrivateChat(result)
            METHOD_TOGGLE_FAVORITE -> toggleFavorite(call, result)
            METHOD_TAKE_PENDING_NAVIGATION ->
                result.success(ChatSerialization.navigation(pendingNavigation.take()))
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
     * is a guard: text is only handed over when upstream's focus is that composer's chat (see
     * [isSameChat]), and otherwise refused with the [ERROR_PRIVATE_CHAT_CHANGED] error (not sent,
     * left in the composer; Dart asks the user to send it again). Dart follows the focus through a
     * debounced snapshot, so for a moment the two can disagree — right after `/m`, or after upstream
     * ends a private chat by itself — and without this check public text could leave as a private
     * message, or worse, private text be broadcast to the public timeline. `false` is then always
     * upstream's own answer (e.g. a blocked peer).
     *
     * The join command (`/j`, `/join`) is never handed over, from either composer: it is answered
     * with the [ERROR_CHANNELS_UNSUPPORTED] error, which Dart shows the user (see [ChatChannels]).
     */
    private fun sendMessage(call: MethodCall, result: MethodChannel.Result) {
        val input = call.composerInput() ?: return result.invalidArguments(call, ComposerInput.EXPECTS)
        val trimmed = input.text.trim()
        if (trimmed.isEmpty()) {
            result.success(false)
            return
        }
        if (ChatChannels.isJoinCommand(trimmed)) {
            return result.error(ERROR_CHANNELS_UNSUPPORTED, "channels are not supported in the Flutter chat", null)
        }
        val privateChat = input.privateChat
        val focus = chatViewModel.selectedPrivateChatPeer.value
        if (!isSameChat(privateChat, focus)) {
            Log.w(TAG, "Not sending: composer is for ${privateChat ?: "the public chat"}, upstream focus is ${focus ?: "the public chat"}")
            return result.error(ERROR_PRIVATE_CHAT_CHANGED, "the composer's chat is not the one upstream has in focus", null)
        }
        chatViewModel.sendMessage(trimmed) { accepted -> result.success(accepted) }
        // Upstream has run a command by the time sendMessage returns (the same `/` test it makes);
        // re-project what its block list hides, which no flow reports.
        if (trimmed.startsWith("/")) commandsRun.update { it + 1 }
    }

    /**
     * Whether text typed in [composer]'s chat (null: the public one) is for upstream's [focus]:
     * the same ID, or another of upstream's IDs for the same person — a mesh peer ID, its Noise key
     * or its `contact_…` conversation, which upstream resolves to one conversation
     * ([privateChatContact], `ContactDirectory`). Upstream re-keys a focused peer to its `contact_…`
     * ID by itself, and Dart only learns the new ID with the next snapshot; without this a send in
     * between was refused. Different people, and the public chat against any private one, never
     * match. IDs are only resolved when they differ, which is what upstream's own private send does
     * next anyway (`ChatViewModel.sendMessage` canonicalizes the focus on this thread too).
     */
    private fun isSameChat(composer: String?, focus: String?): Boolean = when {
        composer == focus -> true
        composer == null || focus == null -> false
        else -> privateChatContact(composer).conversationID == privateChatContact(focus).conversationID
    }

    /**
     * `chat_toggleFavorite({peerID})` → `ChatViewModel.toggleFavorite`, what the star in upstream's
     * private chat header runs: it flips the favourite for the peer's fingerprint, records it in
     * the favourites store (with the peer's Noise key and nickname, so the favourite stays
     * reachable offline) and tells the peer over the mesh when it has a session. [peerID] is the ID
     * the Dart row or screen carries — a mesh peer ID, an offline favourite's Noise key, or the
     * focused `contact_…` conversation; upstream resolves every one. Answers null once upstream
     * ran it; the new star arrives with the `chat_peers` and `chat_selected_private_peer`
     * snapshots.
     */
    private fun toggleFavorite(call: MethodCall, result: MethodChannel.Result) {
        val peerID = call.peerIDArgument() ?: return result.invalidArguments(call, PEER_ID_EXPECTED)
        chatViewModel.toggleFavorite(peerID)
        result.success(null)
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
        val peerID = call.peerIDArgument() ?: return result.invalidArguments(call, PEER_ID_EXPECTED)
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
            result.success(buildSnapshot(::privateChatFocusEvent))
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
            result.success(buildSnapshot(::privateChatFocusEvent))
        }
    }

    /**
     * `chat_openLatestUnreadPrivateChat` → `ChatViewModel.openLatestUnreadPrivateChat`, what the
     * native header's unread envelope runs: upstream picks the unread conversation with the latest
     * incoming message, resolves the peer to open and asks its UI to show that private chat
     * (`showPrivateChatSheet`). The Flutter entry has no such sheet, so the request is handed to Dart
     * instead — answered with its conversation ID, or null when nothing is unread — and withdrawn
     * again (`hidePrivateChatSheet`) so it is answered once. It is cleared before the call too, so a
     * request left by another upstream writer (geohash DMs) is never taken for this call's answer.
     * Dart opens its private chat screen with the ID, which starts the chat like any other
     * (`chat_startPrivateChat`); upstream's start clears the unread mark.
     */
    private fun openLatestUnreadPrivateChat(result: MethodChannel.Result) {
        chatViewModel.hidePrivateChatSheet()
        chatViewModel.openLatestUnreadPrivateChat()
        val conversationID = chatViewModel.privateChatSheetPeer.value
        chatViewModel.hidePrivateChatSheet()
        result.success(conversationID)
    }

    /**
     * `chat_setNickname({nickname})` → `ChatViewModel.setNickname`, which stores it and
     * re-announces on every transport. The nickname is passed exactly as given: upstream itself
     * neither trims nor rejects blank or long nicknames (its header editor saves every keystroke),
     * so the bridge adds no rule. The new value reaches Dart through the `chat_nickname` snapshot.
     */
    private fun setNickname(call: MethodCall, result: MethodChannel.Result) {
        val nickname = call.stringArgument("nickname") ?: return result.invalidArguments(call, "{nickname: String}")
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
     *   the next `chat_selected_private_peer`. The ID is passed as Dart has it: upstream keys drafts
     *   by the canonical conversation (`ConversationListPreferences.setDraft`), so a mesh peer ID
     *   upstream has since re-keyed to `contact_…` still writes that conversation's draft.
     */
    private fun updateInput(call: MethodCall, result: MethodChannel.Result) {
        val (text, privateChat) = call.composerInput() ?: return result.invalidArguments(call, ComposerInput.EXPECTS)
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
        val command = call.stringArgument("command") ?: return result.invalidArguments(call, "{command: String}")
        val suggestion = chatViewModel.commandSuggestions.value.firstOrNull { it.command == command && ChatChannels.isOffered(it) }
        result.success(suggestion?.let(chatViewModel::selectCommandSuggestion))
    }

    /**
     * `chat_selectMentionSuggestion({nickname, currentText})` → the composer's new text from
     * `ChatViewModel.selectMentionSuggestion`, which replaces the `@` fragment being typed and
     * hides the popup.
     */
    private fun selectMentionSuggestion(call: MethodCall, result: MethodChannel.Result) {
        val nickname = call.stringArgument("nickname")
        val currentText = call.stringArgument("currentText")
        if (nickname == null || currentText == null) {
            return result.invalidArguments(call, "{nickname: String, currentText: String}")
        }
        result.success(chatViewModel.selectMentionSuggestion(nickname, currentText))
    }

    /** What a composer hands over: its text, and the private chat it belongs to (null: the public one). */
    private data class ComposerInput(val text: String, val privateChat: String?) {
        companion object {
            const val EXPECTS = "{text: String, privateChat: String?}"
        }
    }

    /** `chat_sendMessage`'s and `chat_updateInput`'s arguments; null when they are invalid. */
    private fun MethodCall.composerInput(): ComposerInput? {
        val text = stringArgument("text") ?: return null
        if (!hasOptionalString("privateChat")) return null
        return ComposerInput(text, stringArgument("privateChat"))
    }

    /** The non-blank `peerID` argument of the private chat and favourite methods; null when invalid. */
    private fun MethodCall.peerIDArgument(): String? = stringArgument("peerID")?.takeIf { it.isNotBlank() }

    /** Every projection pushes its snapshot as soon as it is built (Dart subscribed, or asked). */
    private fun pushSnapshots() {
        if (!scope.isActive) return
        projections.forEach(Projection::requestPush)
    }

    /** Runs [build] on [snapshotDispatcher] (see the class doc); the caller resumes on its own thread. */
    private suspend fun <T> buildSnapshot(build: () -> T): T = withContext(snapshotDispatcher) { build() }

    private fun privateChatFocusEvent(): Map<String, Any?> =
        ChatSerialization.selectedPrivatePeerEvent(currentPrivateChatFocus())

    private fun currentSelf() = ChatSelf(
        peerID = chatViewModel.myPeerID,
        nickname = chatViewModel.nickname.value
    )

    private fun currentPeerInputs(isBlocked: (String) -> Boolean): ChatPeerList.Inputs {
        val connectedPeers = chatViewModel.connectedPeers.value
        val ourFavorites = records.ourFavorites()
        // Only needed to tell which favourites are online (PeopleSection's noiseHexByPeerID and
        // nostrHexByPeerID).
        val matchFavorites = ourFavorites.isNotEmpty()
        // Who the conversations section lists instead (#73); the peers' own aliases (the contact
        // directory) are only looked up while it lists any.
        val conversationAliases = ChatConversations.identityAliases(visibleConversations(isBlocked))
        return ChatPeerList.Inputs(
            myPeerID = chatViewModel.myPeerID,
            connectedPeers = connectedPeers,
            peerNicknames = chatViewModel.peerNicknames.value,
            peerRSSI = chatViewModel.peerRSSI.value,
            peerDirect = chatViewModel.peerDirect.value,
            wifiAwarePeerIDs = wifiAwarePeers.value.keys,
            privateChats = chatViewModel.privateChats.value,
            unreadConversations = ChatBlocking.visibleConversations(
                ChatUnread.conversations(chatViewModel.conversations.value),
                isBlocked
            ),
            favoritePeers = chatViewModel.favoritePeers.value,
            peerFavoritedUs = chatViewModel.peerFavoritedUs.value,
            peerFingerprints = chatViewModel.peerFingerprints.value,
            ourFavorites = ourFavorites,
            peerNoiseKeys = if (matchFavorites) connectedPeers.associateWithNotNull(::noiseKeyHex) else emptyMap(),
            peerNostrKeys = if (matchFavorites) connectedPeers.associateWithNotNull(records::nostrPubkeyHex) else emptyMap(),
            conversationAliases = conversationAliases,
            peerAliases = if (conversationAliases.isNotEmpty()) connectedPeers.associateWith(records::conversationAliases) else emptyMap()
        )
    }

    /** Upstream's conversations the Flutter sheet lists: all but blocked peers' ([ChatBlocking]). */
    private fun visibleConversations(isBlocked: (String) -> Boolean) =
        ChatBlocking.visibleSummaries(chatViewModel.conversations.value, isBlocked)

    /** The `chat_conversations` snapshot (#73), see [ChatConversations]. */
    private fun conversationsEvent(): Map<String, Any?> {
        val inputs = ChatConversations.Inputs(
            conversations = visibleConversations(blockedPeers()),
            peerDirect = chatViewModel.peerDirect.value,
            wifiAwarePeerIDs = wifiAwarePeers.value.keys,
            favoritePeers = chatViewModel.favoritePeers.value,
            peerFavoritedUs = chatViewModel.peerFavoritedUs.value,
            peerFingerprints = chatViewModel.peerFingerprints.value
        )
        return ChatSerialization.conversationsEvent(
            ChatConversations.storeState(chatViewModel.conversationStoreState.value),
            ChatConversations.rows(
                inputs,
                favoriteRelationship = records::favoriteRelationship,
                isFavoriteFallback = favoriteFallbacks.isFavorite,
                isDirectFallback = ::isDirectOnMesh
            )
        )
    }

    /** A connected peer's Noise key as `PeopleSection` finds it: its mesh peer info's, else the cached one. */
    private fun noiseKeyHex(peerID: String): String? =
        runCatching {
            chatViewModel.getMeshPeerInfo(peerID)?.noisePublicKey?.let(ContactIdentityResolver::noiseKeyHex)
        }.getOrNull() ?: records.cachedNoiseKeyHex(peerID)

    private inline fun List<String>.associateWithNotNull(value: (String) -> String?): Map<String, String> =
        mapNotNull { key -> value(key)?.let { key to it } }.toMap()

    /**
     * Upstream's block decision for one snapshot ([ChatBlocking]): nobody while its block list is
     * empty — then no ID is looked up at all — else asked at most once per ID.
     */
    private fun blockedPeers(): (String) -> Boolean =
        if (records.hasBlockedPeers()) ChatBlocking.memo(records::isPeerBlocked) else NOBODY_BLOCKED

    /** The private chat upstream has in focus, resolved as its private chat screen does; null if none. */
    private fun currentPrivateChatFocus(): ChatPrivateChat.Focus? {
        val peerID = chatViewModel.selectedPrivateChatPeer.value ?: return null
        val contact = privateChatContact(peerID)
        val favorite = ChatFavorites.status(
            peerID = peerID,
            fingerprint = ChatPrivateChat.fingerprint(peerID, contact, chatViewModel.peerFingerprints.value),
            favoritePeers = chatViewModel.favoritePeers.value,
            peerFavoritedUs = chatViewModel.peerFavoritedUs.value,
            fallbacks = favoriteFallbacks
        )
        return ChatPrivateChat.Focus(
            peerID = peerID,
            conversationID = contact.conversationID,
            displayName = ChatPrivateChat.displayName(peerID, contact, chatViewModel.peerNicknames.value) {
                runCatching { chatViewModel.resolvePeerDisplayNameForFingerprint(peerID) }.getOrNull()
                    ?: peerID.take(8)
            },
            draft = runCatching { chatViewModel.conversationDraft(peerID) }.getOrNull().orEmpty(),
            isFavorite = favorite.isFavorite,
            theyFavoritedUs = favorite.theyFavoritedUs
        )
    }

    /** `PeopleSection`'s fallback while `peerDirect` has not caught up with a new peer. */
    private fun isDirectOnMesh(peerID: String): Boolean =
        try {
            chatViewModel.getMeshPeerInfo(peerID)?.isDirectConnection == true
        } catch (_: Exception) {
            false
        }

    /**
     * The engine is going away (Activity destroyed or recreated). Stops the projection work and,
     * if a private chat is still selected, ends it (`ChatViewModel.endPrivateChat`), as closing
     * its screen would have: the screen goes with the engine and a new engine starts Dart at its
     * first screen, so nobody is looking at that chat any more. Left selected, upstream would keep
     * counting it as open — sending read receipts for its new messages once the app is back in
     * front, and holding back their notifications (#56). The native UI has no such gap: it
     * restores the open private chat sheet with the Activity.
     */
    fun destroy() {
        scope.cancel()
        removeFavoritesListener()
        if (chatViewModel.selectedPrivateChatPeer.value != null) chatViewModel.endPrivateChat()
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

        /** The native header's unread envelope: answers the conversation to open, or null. */
        const val METHOD_OPEN_LATEST_UNREAD_PRIVATE_CHAT = "chat_openLatestUnreadPrivateChat"

        /**
         * A tapped notification's destination (`ChatSerialization.navigation`), now no longer
         * pending; null when there is none. Dart calls it once it can navigate (#57). Opens nothing
         * upstream: Dart's private chat screen starts the chat as it always does.
         */
        const val METHOD_TAKE_PENDING_NAVIGATION = "chat_takePendingNavigation"

        /** The favourite star (#58): `ChatViewModel.toggleFavorite`, answered null. */
        const val METHOD_TOGGLE_FAVORITE = "chat_toggleFavorite"

        /** `chat_sendMessage` refused the join command: channels are not supported (see [ChatChannels]). */
        const val ERROR_CHANNELS_UNSUPPORTED = "CHANNELS_UNSUPPORTED"

        /**
         * `chat_sendMessage` refused text whose composer is not for the chat upstream has in focus
         * (see [sendMessage]); Dart's focus catches up with the next snapshot, so sending again works.
         */
        const val ERROR_PRIVATE_CHAT_CHANGED = "PRIVATE_CHAT_CHANGED"

        private const val TAG = "ChatBridge"

        private const val PEER_ID_EXPECTED = "{peerID: String}"

        private val NOBODY_BLOCKED: (String) -> Boolean = { false }

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
