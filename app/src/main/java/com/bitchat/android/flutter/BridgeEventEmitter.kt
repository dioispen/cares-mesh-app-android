package com.bitchat.android.flutter

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.CopyOnWriteArrayList

private const val TAG = "BridgeEventEmitter"

private fun mainLooperPoster(): (Runnable) -> Unit {
    val handler = Handler(Looper.getMainLooper())
    return { task -> handler.post(task) }
}

/**
 * The single [EventChannel.StreamHandler] behind the `com.bitchat/bridge/events` channel.
 *
 * A BinaryMessenger keeps only one stream handler per channel name, so every bridge component
 * ([BitchatFlutterChannels], [ChatBridge]) pushes through this shared emitter instead of
 * registering its own. Dart tells events apart by their `type` key.
 *
 * [emit] is safe from any thread. Delivery always hops to the main looper (EventSink is
 * main-thread only) and does not depend on an Activity being alive. An event that cannot be
 * delivered — Dart not listening yet, the listener cancelled, or the engine already cleaned up —
 * is logged with its `type` rather than dropped silently.
 */
class BridgeEventEmitter(
    private val postToMain: (Runnable) -> Unit = mainLooperPoster(),
    private val logDropped: (String) -> Unit = { Log.w(TAG, it) }
) : EventChannel.StreamHandler {

    // Main-thread confined: Flutter calls onListen/onCancel on the platform thread, emit() hops
    // there before reading it, and close() runs from cleanUpFlutterEngine.
    private var sink: EventChannel.EventSink? = null

    @Volatile
    private var closed = false

    private val onListenCallbacks = CopyOnWriteArrayList<() -> Unit>()

    /** Runs [callback] every time Dart (re)subscribes, e.g. to push the current state. */
    fun addOnListenCallback(callback: () -> Unit) {
        onListenCallbacks += callback
    }

    fun emit(event: Map<String, Any?>) {
        postToMain(Runnable { deliver(event) })
    }

    private fun deliver(event: Map<String, Any?>) {
        val target = sink
        when {
            closed -> logDropped("Dropping '${event["type"]}' event: Flutter engine already cleaned up")
            target == null -> logDropped("Dropping '${event["type"]}' event: no Flutter listener attached")
            else -> target.success(event)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        if (closed) return
        sink = events
        onListenCallbacks.forEach { it() }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Engine teardown: stop delivering. Anything still queued or emitted later is logged. */
    fun close() {
        closed = true
        sink = null
        onListenCallbacks.clear()
    }
}
