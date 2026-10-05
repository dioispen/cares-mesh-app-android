package com.bitchat.android.flutter

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.bitchat.android.mesh.MeshDelegate
import com.bitchat.android.mesh.MeshService

/**
 * Makes the chat core ([delegate], the headless `ChatViewModel`) the [mesh] delegate exactly while
 * the Flutter entry is resumed, as `MainActivity.onResume` / `onPause` do (#50). Observe it from
 * the Activity's lifecycle.
 *
 * Being the delegate is what "the app is in the foreground" means to upstream's chat (#56), so this
 * is the one place the Flutter entry decides it:
 * - Read receipts: upstream sends one for a message arriving in the open private chat only from
 *   the delegate's `didReceiveMessage` (`MeshDelegateHandler.sendReadReceiptIfFocused`). The
 *   background flag that check also reads is never set on `ChatViewModel`'s own
 *   `NotificationManager`, so while paused — even with the private chat screen still open behind
 *   the home screen — no receipt goes out. Coming back sends none for what arrived meanwhile;
 *   upstream sends those the next time the chat is opened (`startPrivateChat`).
 * - Private message notifications: with no delegate `BluetoothMeshService` posts them itself;
 *   while attached, `ChatViewModel`'s `NotificationManager` posts one unless that chat is open.
 * - Queued private messages: `MessageRouter` also flushes them on the delegate's peer list updates
 *   (it does so without one when a Noise session comes up, and on its own outbox tick).
 */
internal class ForegroundMeshDelegate(
    private val mesh: MeshService,
    private val delegate: () -> MeshDelegate
) : DefaultLifecycleObserver {

    private var resumed = false

    override fun onResume(owner: LifecycleOwner) {
        resumed = true
        mesh.delegate = delegate()
    }

    override fun onPause(owner: LifecycleOwner) {
        resumed = false
        mesh.delegate = null
    }

    /**
     * A transport started while the entry is in front (Wi-Fi Aware coming up after the UI):
     * assigning the delegate again makes the unified mesh service attach that transport too.
     * Nothing happens while paused.
     */
    fun reattach() {
        if (resumed) mesh.delegate = delegate()
    }
}
