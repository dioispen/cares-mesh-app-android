package com.bitchat.android.flutter

import com.bitchat.android.testsupport.ManualPoster
import com.bitchat.android.testsupport.RecordingSink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeEventEmitterTest {

    private val poster = ManualPoster()
    private val logs = mutableListOf<String>()
    private val emitter = BridgeEventEmitter(postToMain = poster, logDropped = { logs += it })

    @Test
    fun `events are delivered through the main poster rather than inline`() {
        val sink = RecordingSink()
        emitter.onListen(null, sink)

        emitter.emit(mapOf("type" to "packet", "packetType" to 0x30))

        assertTrue("delivered before the main looper ran", sink.events.isEmpty())
        poster.runAll()
        assertEquals(listOf(mapOf("type" to "packet", "packetType" to 0x30)), sink.events)
        assertTrue(logs.isEmpty())
    }

    @Test
    fun `event emitted before Flutter listens is logged with its type instead of vanishing`() {
        emitter.emit(mapOf("type" to "system_status"))
        poster.runAll()

        assertEquals(1, logs.size)
        assertTrue(logs.single(), logs.single().contains("system_status"))
    }

    @Test
    fun `event emitted after Flutter cancels is logged`() {
        val sink = RecordingSink()
        emitter.onListen(null, sink)
        emitter.onCancel(null)

        emitter.emit(mapOf("type" to "packet"))
        poster.runAll()

        assertTrue(sink.events.isEmpty())
        assertEquals(1, logs.size)
        assertTrue(logs.single(), logs.single().contains("packet"))
    }

    @Test
    fun `closed emitter never reaches the old sink and logs the drop`() {
        val sink = RecordingSink()
        emitter.onListen(null, sink)
        emitter.close()

        emitter.emit(mapOf("type" to "packet"))
        poster.runAll()

        assertTrue(sink.events.isEmpty())
        assertEquals(1, logs.size)
    }

    @Test
    fun `event queued before close but run after close is dropped with a log`() {
        val sink = RecordingSink()
        emitter.onListen(null, sink)

        emitter.emit(mapOf("type" to "packet"))
        emitter.close()
        poster.runAll()

        assertTrue(sink.events.isEmpty())
        assertEquals(1, logs.size)
    }

    @Test
    fun `on-listen callbacks run when Flutter starts listening`() {
        emitter.addOnListenCallback { emitter.emit(mapOf("type" to "system_status")) }
        val sink = RecordingSink()

        emitter.onListen(null, sink)
        poster.runAll()

        assertEquals(listOf(mapOf("type" to "system_status")), sink.events)
    }

    @Test
    fun `closed emitter does not run on-listen callbacks`() {
        var ran = false
        emitter.addOnListenCallback { ran = true }
        emitter.close()

        emitter.onListen(null, RecordingSink())
        poster.runAll()

        assertEquals(false, ran)
    }
}
