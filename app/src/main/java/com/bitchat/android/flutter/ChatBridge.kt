package com.bitchat.android.flutter

import com.bitchat.android.ui.ChatViewModel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * Chat half of the Flutter bridge (#49).
 *
 * The upstream [ChatViewModel] stays the single source of truth for chat behaviour. This class
 * only projects its state to Flutter (`chat_*` typed events through the shared [events] emitter)
 * and forwards Flutter's chat actions to the ViewModel's existing methods; it holds no chat logic
 * of its own.
 *
 * It owns no channel. [BitchatFlutterChannels] registers the one method handler and the one
 * stream handler, and offers this bridge every method it does not recognise
 * (see [BridgeMethodDispatcher]).
 *
 * Lifetime is one Flutter engine: created in `FlutterChatActivity.configureFlutterEngine` and
 * [destroy]ed in `cleanUpFlutterEngine`. The ViewModel outlives it across Activity recreation, so
 * projection work runs in [scope] — never in `viewModelScope` — and stops with the engine.
 */
class ChatBridge(
    private val chatViewModel: ChatViewModel,
    private val events: BridgeEventEmitter,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
) : BridgeMethodHandler {

    /** No chat methods yet; they arrive with the projection tickets (#51 onward). */
    override fun handle(call: MethodCall, result: MethodChannel.Result): Boolean = false

    fun destroy() {
        scope.cancel()
    }
}
