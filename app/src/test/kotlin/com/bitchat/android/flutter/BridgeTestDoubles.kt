package com.bitchat.android.flutter

import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Records how a MethodChannel.Result was completed, in order. */
internal class RecordingResult : MethodChannel.Result {
    val calls = mutableListOf<String>()

    /** The values passed to [success], unformatted. */
    val values = mutableListOf<Any?>()

    override fun success(result: Any?) {
        calls += "success:$result"
        values += result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        calls += "error:$errorCode"
    }

    override fun notImplemented() {
        calls += "notImplemented"
    }
}

/** Records events delivered to the Dart side. */
internal class RecordingSink : EventChannel.EventSink {
    val events = mutableListOf<Any?>()

    override fun success(event: Any?) {
        events += event
    }

    override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        events += "error:$errorCode"
    }

    override fun endOfStream() {
        events += "endOfStream"
    }
}

/** A main-looper stand-in: queues posted work until [runAll] is called. */
internal class ManualPoster : (Runnable) -> Unit {
    private val queue = ArrayDeque<Runnable>()

    val pending: Int
        get() = queue.size

    override fun invoke(task: Runnable) {
        queue.addLast(task)
    }

    fun runAll() {
        while (queue.isNotEmpty()) queue.removeFirst().run()
    }
}
