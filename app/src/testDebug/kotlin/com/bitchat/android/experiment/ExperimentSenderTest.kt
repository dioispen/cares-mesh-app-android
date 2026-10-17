package com.bitchat.android.experiment

import com.bitchat.android.protocol.HealthStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneOffset

/** Start time, count and interval of the experiment sender, on an injected clock (#70). */
@OptIn(ExperimentalCoroutinesApi::class)
class ExperimentSenderTest {
    /** 2026-10-04 09:59:50 UTC: ten seconds before the 10:00:00 start the tests use. */
    private val base = LocalDateTime.of(2026, 10, 4, 9, 59, 50).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val tenOClock = base + 10_000

    private val sent = mutableListOf<Long>()

    /** How far the phone's wall clock jumped while the CPU slept (the test scheduler does not see it). */
    private var sleptMs = 0L
    private val keepAwake = RecordingKeepAwake()
    private var accept = true

    private fun TestScope.sender() = ExperimentSender(
        scope = backgroundScope,
        clock = { base + testScheduler.currentTime + sleptMs },
        zone = ZoneOffset.UTC,
        keepAwake = keepAwake
    ) { _, pts ->
        sent += pts
        accept
    }

    /** Runs the sender to completion. It lives in `backgroundScope`, which `advanceUntilIdle` skips. */
    private fun TestScope.finish() {
        advanceTimeBy(48 * 3_600_000L)
        runCurrent()
    }

    private fun plan(
        count: Int = 3,
        intervalMs: Long = 1_000,
        startAt: LocalTime? = LocalTime.of(10, 0, 0),
        keepAwake: Boolean = true
    ) = ExperimentPlan(
        handle = "ee0000000001",
        status = HealthStatus.SAFE,
        count = count,
        intervalMs = intervalMs,
        ttl = 7,
        startAt = startAt,
        keepAwake = keepAwake
    )

    @Test
    fun `waits for the wall-clock start, then sends count packets an interval apart`() = runTest {
        val sender = sender()

        val started = sender.start(plan())

        assertTrue(started is ExperimentSender.StartResult.Started)
        assertEquals(ExperimentSender.State.WAITING, sender.status.state)
        assertEquals(tenOClock, sender.status.startsAtMs)
        advanceTimeBy(9_999)
        assertEquals(emptyList<Long>(), sent)

        finish()

        assertEquals(listOf(tenOClock, tenOClock + 1_000, tenOClock + 2_000), sent)
        assertEquals(ExperimentSender.State.DONE, sender.status.state)
        assertEquals(3, sender.status.sent)
        assertEquals(3, sender.status.total)
    }

    @Test
    fun `reports SENDING while the run is under way`() = runTest {
        val sender = sender()
        sender.start(plan())

        advanceTimeBy(10_500)

        assertEquals(ExperimentSender.State.SENDING, sender.status.state)
        assertEquals(1, sender.status.sent)
    }

    @Test
    fun `a start time already past today means the same time tomorrow`() = runTest {
        val sender = sender()

        sender.start(plan(startAt = LocalTime.of(9, 0, 0)))

        assertEquals(tenOClock + 23 * 3_600_000L, sender.status.startsAtMs)
    }

    @Test
    fun `without a start time the first packet goes out at once`() = runTest {
        val sender = sender()

        sender.start(plan(startAt = null))
        runCurrent()

        assertEquals(listOf(base), sent)
    }

    @Test
    fun `a zero interval bursts every packet with its own timestamp`() = runTest {
        val sender = sender()

        sender.start(plan(count = 4, intervalMs = 0, startAt = null))
        runCurrent()

        assertEquals(listOf(base, base + 1, base + 2, base + 3), sent)
        assertEquals(0L, testScheduler.currentTime)
    }

    @Test
    fun `stopping ends the run, nothing more is sent and the wake lock is released`() = runTest {
        val sender = sender()
        sender.start(plan(count = 10))
        advanceTimeBy(11_500)

        val stopped = sender.stop()
        finish()

        assertEquals(2, sent.size)
        assertEquals(ExperimentSender.State.STOPPED, stopped.state)
        assertEquals(ExperimentSender.State.STOPPED, sender.status.state)
        assertEquals(listOf("acquire", "release"), keepAwake.calls.map { it.substringBefore(':') })
    }

    @Test
    fun `a second start while one is running is refused`() = runTest {
        val sender = sender()
        sender.start(plan())

        val second = sender.start(plan(count = 99))

        assertSame(ExperimentSender.StartResult.AlreadyRunning, second)
        assertEquals(3, sender.status.total)
    }

    @Test
    fun `a finished run can be followed by a new one`() = runTest {
        val sender = sender()
        sender.start(plan(count = 1, startAt = null))
        finish()

        assertTrue(sender.start(plan(count = 1, startAt = null)) is ExperimentSender.StartResult.Started)
        finish()

        assertEquals(2, sent.size)
    }

    @Test
    fun `packets the mesh did not take are counted as failed`() = runTest {
        accept = false
        val sender = sender()

        sender.start(plan(count = 2, startAt = null))
        finish()

        assertEquals(0, sender.status.sent)
        assertEquals(2, sender.status.failed)
        assertEquals(ExperimentSender.State.DONE, sender.status.state)
    }

    @Test
    fun `the wake lock covers the wait and the whole run`() = runTest {
        val sender = sender()

        sender.start(plan(count = 3, intervalMs = 1_000))
        finish()

        assertEquals(
            listOf("acquire:${10_000 + 2_000 + ExperimentSender.WAKE_LOCK_MARGIN_MS}", "release"),
            keepAwake.calls
        )
    }

    @Test
    fun `each sent packet is later counted as written to links or as having no link`() = runTest {
        val sender = sender()
        sender.start(plan(count = 3, intervalMs = 0, startAt = null))
        runCurrent()

        sender.onWritten(base, fanout = 2)
        sender.onWritten(base + 1, fanout = 0)

        assertEquals(1, sender.status.written)
        assertEquals(1, sender.status.noLink)
        assertEquals(ExperimentSender.State.DONE, sender.status.state)
        sender.onWritten(base + 2, fanout = 1)
        assertEquals("a write reported after the run finished still counts", 2, sender.status.written)
    }

    @Test
    fun `writes of packets this run did not send are ignored, even repeated ones`() = runTest {
        val sender = sender()
        sender.start(plan(count = 1, startAt = null))
        runCurrent()

        sender.onWritten(base - 5_000, fanout = 3)
        sender.onWritten(base, fanout = 3)
        sender.onWritten(base, fanout = 3)

        assertEquals(1, sender.status.written)
        assertEquals(0, sender.status.noLink)
    }

    @Test
    fun `packets the mesh did not take are never counted as written`() = runTest {
        accept = false
        val sender = sender()
        sender.start(plan(count = 1, startAt = null))
        runCurrent()

        sender.onWritten(base, fanout = 1)

        assertEquals(0, sender.status.written)
        assertEquals(1, sender.status.failed)
    }

    @Test
    fun `a new run starts its write counts from zero`() = runTest {
        val sender = sender()
        sender.start(plan(count = 1, startAt = null))
        runCurrent()
        sender.onWritten(base, fanout = 0)

        sender.start(plan(count = 1, startAt = null))

        assertEquals(0, sender.status.noLink)
    }

    @Test
    fun `a run that must not keep the phone awake never takes the wake lock`() = runTest {
        val sender = sender()

        sender.start(plan(count = 2, intervalMs = 60_000, startAt = null, keepAwake = false))
        finish()

        assertEquals(2, sent.size)
        assertEquals(emptyList<String>(), keepAwake.calls)
    }

    @Test
    fun `after the CPU slept through slots, sending resumes one interval at a time instead of bursting`() = runTest {
        val sender = sender()
        sender.start(plan(count = 3, intervalMs = 60_000, startAt = null, keepAwake = false))
        runCurrent()

        sleptMs = 600_000
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(listOf(base, base + 660_000), sent)

        advanceTimeBy(59_999)
        runCurrent()
        assertEquals("the next one keeps a full interval", 2, sent.size)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(base, base + 660_000, base + 720_000), sent)
    }

    private class RecordingKeepAwake : KeepAwake {
        val calls = mutableListOf<String>()
        override fun acquire(timeoutMs: Long) {
            calls += "acquire:$timeoutMs"
        }

        override fun release() {
            calls += "release"
        }
    }
}
