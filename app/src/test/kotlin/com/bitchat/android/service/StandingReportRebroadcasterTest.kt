package com.bitchat.android.service

import android.os.Build
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * ADR-0010：舉著 SOS 或受傷的 Health Report，由 Reporter 的裝置每 30 分鐘以新的封包時間戳重發，
 * payload 原封不動。
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class StandingReportRebroadcasterTest {

    private val myPeerID = "0102030405060708"
    private val handle = "abcdef012345"
    private val base = 1_800_000_000_000L
    private val interval = AppConstants.Sync.STANDING_REPORT_RESEND_INTERVAL_MS
    private val minute = 60_000L

    // ── 排程（純函式）────────────────────────────────────────────────────────

    @Test
    fun `nothing is re-sent without a kept report or once the Reporter is safe`() {
        assertTrue(StandingHealthReport.next(null, base) is StandingHealthReport.Idle)
        assertTrue(StandingHealthReport.next(report(HealthStatus.SAFE, sos = false, at = base), base) is StandingHealthReport.Idle)
    }

    @Test
    fun `an SOS or an injury stands, whatever the Status`() {
        listOf(
            report(HealthStatus.UNDECLARED, sos = true, at = base),
            report(HealthStatus.MINOR, sos = true, at = base),
            report(HealthStatus.MINOR, sos = false, at = base),
            report(HealthStatus.SEVERE, sos = false, at = base)
        ).forEach { assertTrue(StandingHealthReport.isStanding(it)) }
        assertTrue(!StandingHealthReport.isStanding(report(HealthStatus.SAFE, sos = false, at = base)))
    }

    @Test
    fun `a field-experiment report is never re-sent`() {
        val experiment = report(HealthStatus.SEVERE, sos = false, at = base, reporterHandle = "ee0000000003")

        assertTrue(StandingHealthReport.next(experiment, base) is StandingHealthReport.Idle)
    }

    @Test
    fun `the re-send is due one interval after the last send, with the payload unchanged`() {
        val kept = report(HealthStatus.SEVERE, sos = true, at = base)

        val step = StandingHealthReport.next(kept, base + 10 * minute) as StandingHealthReport.Resend

        assertEquals(base + interval, step.atMs)
        assertArrayEquals(kept.payload.copyOfRange(1, kept.payload.size), step.payload)
    }

    @Test
    fun `a report from before a long outage is due at once`() {
        val kept = report(HealthStatus.SEVERE, sos = true, at = base - 3 * 60 * minute)

        val step = StandingHealthReport.next(kept, base) as StandingHealthReport.Resend

        assertTrue(step.atMs <= base)
    }

    @Test
    fun `a timestamp ahead of a clock set back counts as sent now`() {
        val kept = report(HealthStatus.SEVERE, sos = true, at = base + 5 * 60 * minute)

        val step = StandingHealthReport.next(kept, base) as StandingHealthReport.Resend

        assertEquals(base + interval, step.atMs)
    }

    @Test
    fun `a re-send not kept yet counts as the last send`() {
        val kept = report(HealthStatus.SEVERE, sos = true, at = base - interval)

        val step = StandingHealthReport.next(kept, base, resentAtMs = base) as StandingHealthReport.Resend

        assertEquals(base + interval, step.atMs)
    }

    // ── 重發器 ──────────────────────────────────────────────────────────────

    @Test
    fun `re-sends every interval from the last send, without a burst at start`() = runTest {
        val mesh = FakeMesh(this, report(HealthStatus.SEVERE, sos = true, at = base - 10 * minute))
        mesh.start()

        advanceTimeBy(2 * 60 * minute + 1)

        assertEquals(listOf(20, 50, 80, 110).map { base + it * minute }, mesh.sentAt)
    }

    @Test
    fun `after a long outage it sends once at start, then every interval`() = runTest {
        val mesh = FakeMesh(this, report(HealthStatus.MINOR, sos = false, at = base - 3 * 60 * minute))
        mesh.start()

        advanceTimeBy(interval + 1)

        assertEquals(listOf(base, base + interval), mesh.sentAt)
    }

    @Test
    fun `every re-send carries the same Broadcast Tier bytes`() = runTest {
        val original = report(HealthStatus.UNDECLARED, sos = true, at = base - interval)
        val mesh = FakeMesh(this, original)
        mesh.start()

        advanceTimeBy(2 * interval + 1)

        assertEquals(3, mesh.payloads.size)
        mesh.payloads.forEach { assertArrayEquals(original.payload.copyOfRange(1, original.payload.size), it) }
    }

    @Test
    fun `a report the Reporter sends meanwhile restarts the wait from it`() = runTest {
        val mesh = FakeMesh(this, report(HealthStatus.SEVERE, sos = true, at = base))
        mesh.start()

        advanceTimeBy(20 * minute)
        mesh.reporterSends(report(HealthStatus.MINOR, sos = true, at = base + 20 * minute))
        advanceTimeBy(30 * minute + 1)

        assertEquals(listOf(base + 50 * minute), mesh.sentAt)
    }

    @Test
    fun `declaring safe stops the re-sends`() = runTest {
        val mesh = FakeMesh(this, report(HealthStatus.SEVERE, sos = true, at = base))
        mesh.start()

        advanceTimeBy(20 * minute)
        mesh.reporterSends(report(HealthStatus.SAFE, sos = false, at = base + 20 * minute))
        advanceTimeBy(5 * 60 * minute)

        assertEquals(emptyList<Long>(), mesh.sentAt)
    }

    @Test
    fun `a panic wipe stops the re-sends`() = runTest {
        val mesh = FakeMesh(this, report(HealthStatus.SEVERE, sos = true, at = base))
        mesh.start()

        advanceTimeBy(20 * minute)
        mesh.wipe()
        advanceTimeBy(5 * 60 * minute)

        assertEquals(emptyList<Long>(), mesh.sentAt)
    }

    @Test
    fun `while the mesh is not running it retries after a few minutes, not in a burst`() = runTest {
        val mesh = FakeMesh(this, report(HealthStatus.SEVERE, sos = true, at = base - interval))
        mesh.running = false
        mesh.start()

        advanceTimeBy(StandingReportRebroadcaster.SEND_RETRY_MS * 2 + 1)
        mesh.running = true
        advanceTimeBy(StandingReportRebroadcaster.SEND_RETRY_MS + 1)

        // Failed at 0, 5 and 10 min; sent at 15 min, and then not again until an interval later
        assertEquals(4, mesh.attempts)
        assertEquals(listOf(base + 3 * StandingReportRebroadcaster.SEND_RETRY_MS), mesh.sentAt)
    }

    @Test
    fun `a re-send the keeper does not take still waits a full interval for the next`() = runTest {
        val mesh = FakeMesh(this, report(HealthStatus.SEVERE, sos = true, at = base - interval))
        mesh.keepsResends = false
        mesh.start()

        advanceTimeBy(interval + 1)

        assertEquals(listOf(base, base + interval), mesh.sentAt)
    }

    /** The kept report (P0-3) and the mesh it is sent through, on the test's virtual clock. */
    private inner class FakeMesh(private val test: TestScope, initial: BitchatPacket?) {
        private var kept: BitchatPacket? = initial
        private val changes = MutableStateFlow(0L)
        var running = true
        var keepsResends = true
        var attempts = 0
        val sentAt = mutableListOf<Long>()
        val payloads = mutableListOf<ByteArray>()

        private fun now() = base + test.testScheduler.currentTime

        fun start() {
            StandingReportRebroadcaster(
                latestOwnReport = { kept },
                send = ::send,
                changes = changes,
                nowMs = ::now
            ).start(test.backgroundScope)
            test.runCurrent()
        }

        /** What BluetoothMeshService does: sign under a new timestamp, broadcast, keep it. */
        private fun send(payload: ByteArray): Boolean {
            attempts++
            if (!running) return false
            sentAt += now()
            payloads += payload
            if (keepsResends) {
                kept = HealthReportBroadcast.packet(myPeerID, payload, timestamp = now()).copy(signature = SIGNATURE)
                changes.value++
            }
            return true
        }

        fun reporterSends(packet: BitchatPacket) {
            kept = packet
            changes.value++
            test.runCurrent()
        }

        fun wipe() {
            kept = null
            changes.value++
            test.runCurrent()
        }
    }

    private fun report(
        status: HealthStatus,
        sos: Boolean,
        at: Long,
        reporterHandle: String = handle
    ): BitchatPacket {
        // reportTime is when the Reporter made the statement; re-sends never change it
        val payload = HealthReportPayload(reporterHandle, status, "wsqqqm", reportTimeMillis = at, sos = sos).encode()
        return HealthReportBroadcast.packet(myPeerID, payload, timestamp = at).copy(signature = SIGNATURE)
    }

    private companion object {
        val SIGNATURE = ByteArray(64) { 7 }
    }
}
