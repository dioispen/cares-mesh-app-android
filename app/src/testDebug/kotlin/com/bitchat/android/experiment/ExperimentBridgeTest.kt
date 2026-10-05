package com.bitchat.android.experiment

import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.testsupport.RecordingResult
import io.flutter.plugin.common.MethodCall
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.time.LocalTime
import java.time.ZoneOffset

/** The `experiment_*` methods the debug-only Flutter field screen calls (#70). */
@OptIn(ExperimentalCoroutinesApi::class)
class ExperimentBridgeTest {
    private val now = 1_790_000_000_000L
    private val counter = ExperimentRxCounter { now }
    private val plans = mutableListOf<ExperimentPlan>()
    private var sender: ExperimentSender? = null

    private val bridge = ExperimentBridge(probe = FixedProbe, rxCounter = counter, sender = { sender })

    private fun TestScope.installSender() {
        sender = ExperimentSender(
            scope = backgroundScope,
            clock = { now + testScheduler.currentTime },
            zone = ZoneOffset.UTC,
            keepAwake = KeepAwake.None
        ) { plan, _ ->
            plans += plan
            true
        }
    }

    private fun call(method: String, arguments: Any? = null): RecordingResult {
        val result = RecordingResult()
        val claimed = bridge.handle(MethodCall(method, arguments), result)
        assert(claimed) { "$method was not claimed" }
        return result
    }

    private val validStart = mapOf(
        "device" to 3,
        "count" to 50,
        "intervalMs" to 1_000,
        "ttl" to 7,
        "startAt" to "10:00:00",
        "status" to "安全"
    )

    @Test
    fun `status reports links, power mode, our peer and per-handle RX counts`() {
        counter.record("ee0000000002", now - 5_000)
        counter.record("ee0000000002", now - 30_000)

        val status = call(ExperimentBridge.METHOD_GET_STATUS).values.single() as Map<*, *>

        assertEquals(2, status["links"])
        assertEquals("BALANCED", status["powerMode"])
        assertEquals("00112233", status["peerId"])
        assertEquals(mapOf("ee0000000002" to 1), status["rx20s"])
        assertEquals(mapOf("ee0000000002" to 2), status["rx60s"])
        assertEquals(false, status["systemPowerSave"])
        assertEquals("idle", (status["sender"] as Map<*, *>)["state"])
    }

    @Test
    fun `ten phones take part, the tenth sending as ee0000000010`() = runTest {
        installSender()

        val answer = call(ExperimentBridge.METHOD_START_SENDER, validStart + ("device" to 10)).values.single() as Map<*, *>

        assertEquals("ee0000000010", answer["handle"])
    }

    @Test
    fun `the sender status separates packets written to links from those with no link`() = runTest {
        installSender()
        call(ExperimentBridge.METHOD_START_SENDER, validStart + ("startAt" to null) + ("count" to 2) + ("intervalMs" to 0))
        testScheduler.runCurrent()
        sender!!.onWritten(now, fanout = 2)
        sender!!.onWritten(now + 1, fanout = 0)

        val answer = (call(ExperimentBridge.METHOD_GET_STATUS).values.single() as Map<*, *>)["sender"] as Map<*, *>

        assertEquals(2, answer["sent"])
        assertEquals(1, answer["written"])
        assertEquals(1, answer["noLink"])
    }

    @Test
    fun `start hands the sender the plan for this device's experiment handle`() = runTest {
        installSender()

        val answer = call(ExperimentBridge.METHOD_START_SENDER, validStart).values.single() as Map<*, *>

        assertEquals("waiting", answer["state"])
        assertEquals("ee0000000003", answer["handle"])
        assertEquals(50, answer["total"])
        assertEquals(7, answer["ttl"])
        assertEquals(1_000L, answer["intervalMs"])
        assertEquals(
            ExperimentPlan("ee0000000003", HealthStatus.SAFE, 50, 1_000, 7, LocalTime.of(10, 0, 0)),
            sender!!.status.plan
        )
    }

    @Test
    fun `keeping the phone awake is on unless the run turns it off`() = runTest {
        installSender()

        call(ExperimentBridge.METHOD_START_SENDER, validStart)
        assertEquals(true, sender!!.status.plan!!.keepAwake)
        sender!!.stop()

        val answer = call(ExperimentBridge.METHOD_START_SENDER, validStart + ("keepAwake" to false)).values.single() as Map<*, *>
        assertEquals(false, sender!!.status.plan!!.keepAwake)
        assertEquals(false, answer["keepAwake"])
    }

    @Test
    fun `start without a start time begins at once`() = runTest {
        installSender()

        call(ExperimentBridge.METHOD_START_SENDER, validStart + ("startAt" to null))

        assertEquals(now, sender!!.status.startsAtMs)
    }

    @Test
    fun `start refuses arguments outside the experiment's range`() = runTest {
        installSender()
        val invalid = listOf(
            validStart + ("device" to 0),
            validStart + ("device" to 11),
            validStart + ("count" to 0),
            validStart + ("intervalMs" to -1),
            validStart + ("ttl" to 5),
            validStart + ("ttl" to 7.0),
            validStart + ("startAt" to "25:00:00"),
            validStart + ("startAt" to "10:00"),
            validStart + ("status" to "unknown"),
            validStart + ("keepAwake" to "no"),
            validStart - "count"
        )

        invalid.forEach { arguments ->
            assertEquals("$arguments", listOf("error:INVALID_ARGUMENT"), call(ExperimentBridge.METHOD_START_SENDER, arguments).calls)
        }
        assertEquals(ExperimentSender.State.IDLE, sender!!.status.state)
    }

    @Test
    fun `start before the mesh service exists says so`() {
        assertEquals(
            listOf("error:SERVICE_NOT_READY"),
            call(ExperimentBridge.METHOD_START_SENDER, validStart).calls
        )
    }

    @Test
    fun `a second start while one is running is refused`() = runTest {
        installSender()
        call(ExperimentBridge.METHOD_START_SENDER, validStart)

        assertEquals(
            listOf("error:ALREADY_RUNNING"),
            call(ExperimentBridge.METHOD_START_SENDER, validStart).calls
        )
    }

    @Test
    fun `stop ends the run and answers the sender status`() = runTest {
        installSender()
        call(ExperimentBridge.METHOD_START_SENDER, validStart)

        val answer = call(ExperimentBridge.METHOD_STOP_SENDER).values.single() as Map<*, *>

        assertEquals("stopped", answer["state"])
    }

    @Test
    fun `stop with no sender has nothing to stop`() {
        val answer = call(ExperimentBridge.METHOD_STOP_SENDER).values.single() as Map<*, *>

        assertEquals("idle", answer["state"])
    }

    @Test
    fun `other methods are left to the next handler`() {
        val result = RecordingResult()

        assertFalse(bridge.handle(MethodCall("getSystemStatus", null), result))
        assertEquals(emptyList<String>(), result.calls)
    }

    private object FixedProbe : MeshProbe {
        override fun myPeerID(): String = "0011223344556677"
        override fun powerMode(): String = "BALANCED"
        override fun linkCount(): Int = 2
        override fun systemPowerSave(): Boolean = false
        override fun peerAt(address: String): String? = null
        override fun links(): List<MeshProbe.Link> = emptyList()
    }
}
