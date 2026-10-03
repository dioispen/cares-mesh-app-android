package com.bitchat.android.flutter

import android.content.Intent
import androidx.lifecycle.ViewModel
import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.ui.NotificationManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.getAndUpdate

/**
 * The chat screen a tapped notification asks the Flutter UI to show (#57).
 *
 * Upstream's notifications (`ui.NotificationManager`) name their destination in intent extras, read
 * by `MainActivity.handleNotificationIntent`. Their taps now open [FlutterChatActivity], which reads
 * the same extras ([fromNotification]). It cannot open the screen itself as `MainActivity` does —
 * only Dart knows when it may navigate (after its own setup and sign-in) — so the request waits in
 * [PendingChatNavigation] until Dart takes it (`chat_takePendingNavigation`).
 */
sealed interface ChatNavigation {

    /**
     * A private message notification (or a verification one about a peer): open the private chat
     * with [peerID], upstream's conversation ID for the sender. [senderNickname] is the name the
     * notification showed, kept as upstream passes it.
     */
    data class PrivateChat(val peerID: String, val senderNickname: String?) : ChatNavigation {
        override fun clearNotifications(chatViewModel: ChatViewModel) =
            chatViewModel.clearNotificationsForSender(peerID)
    }

    /** A mesh @mention notification: show the public chat. */
    data object PublicChat : ChatNavigation {
        override fun clearNotifications(chatViewModel: ChatViewModel) =
            chatViewModel.clearMeshMentionNotifications()
    }

    /**
     * What `MainActivity.handleNotificationIntent` does besides opening the chat: drop the
     * notifications of the chat the user is now going to (for a mention, of the public chat — what
     * upstream does when the user is back in it, `endPrivateChat`).
     */
    fun clearNotifications(chatViewModel: ChatViewModel)

    companion object {
        /**
         * Where [intent] asks to go, if it is a tapped chat notification; null for every other
         * launch (launcher, the mesh service's own notification, a summary notification) — those
         * only bring the app to the front. A relaunch from recents is never one: its intent is the
         * one that first started the task, possibly a notification long since dealt with.
         */
        fun fromNotification(intent: Intent): ChatNavigation? = fromNotification(
            launchedFromHistory = intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0,
            flag = { intent.getBooleanExtra(it, false) },
            text = intent::getStringExtra
        )

        /**
         * [fromNotification] over the extras, read with [flag] and [text]. Same order as
         * `MainActivity.handleNotificationIntent`: a private chat first (with no peer ID nothing
         * opens), then the mesh chat. Geohash chats have no Flutter screen (P3), so theirs go
         * nowhere.
         */
        internal fun fromNotification(
            launchedFromHistory: Boolean,
            flag: (String) -> Boolean,
            text: (String) -> String?
        ): ChatNavigation? {
            if (launchedFromHistory) return null
            if (flag(NotificationManager.EXTRA_OPEN_PRIVATE_CHAT)) {
                val peerID = text(NotificationManager.EXTRA_PEER_ID)?.takeIf { it.isNotBlank() } ?: return null
                return PrivateChat(peerID, text(NotificationManager.EXTRA_SENDER_NICKNAME))
            }
            if (flag(NotificationManager.EXTRA_OPEN_MESH_CHAT)) return PublicChat
            return null
        }
    }
}

/**
 * The notification tap Dart has not acted on yet (#57): the latest tap wins, and Dart takes it
 * exactly once ([take]). [pending] is projected to Dart as `chat_pending_navigation`.
 *
 * A ViewModel of [FlutterChatActivity]: it outlives the Activity being recreated (a rotation while
 * Dart is still on its setup or sign-in screens, which recreates the engine too) and goes away with
 * the Activity, so a tap is never replayed into a later launch.
 */
class PendingChatNavigation : ViewModel() {
    private val _pending = MutableStateFlow<ChatNavigation?>(null)
    val pending: StateFlow<ChatNavigation?> = _pending.asStateFlow()

    fun offer(navigation: ChatNavigation) {
        _pending.value = navigation
    }

    /** The pending request, now no longer pending; null if there is none. */
    fun take(): ChatNavigation? = _pending.getAndUpdate { null }
}
