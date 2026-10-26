package com.bitchat.android.gateway

import android.os.Build
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Gateway（#111，ADR-0009）：只看對外行為——給定收到的回報、網路與登入狀態、時間流逝，
 * 觀察對上傳 port 的呼叫。上傳 port 與時鐘都是 fake。
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class MeshGatewayTest {

    private var now = 1_800_000_000_000L
    private val uploader = FakeUploader()

    // ── 上傳條件 ─────────────────────────────────────────────────────────────

    @Test
    fun `a fresh report is uploaded at once while signed in and online`() = runTest {
        val gateway = gateway()
        val report = heard()

        gateway.onReport(report)
        runCurrent()

        assertEquals(listOf(report to GATEWAY_UID), uploader.uploads)
    }

    @Test
    fun `nothing is uploaded while signed out`() = runTest {
        val gateway = gateway(uid = null)

        gateway.onReport(heard())
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `signing out stops the uploads`() = runTest {
        val gateway = gateway()
        gateway.onSignedIn(null)

        gateway.onReport(heard())
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `nothing is uploaded without a network`() = runTest {
        val gateway = gateway(online = false)

        gateway.onReport(heard())
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `losing the network stops the uploads`() = runTest {
        val gateway = gateway()
        gateway.onNetworkChanged(false)

        gateway.onReport(heard())
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `a report older than two hours is not uploaded`() = runTest {
        val gateway = gateway()

        gateway.onReport(heard(reportTimeMs = now - TWO_HOURS_MS - 1_000))
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `a report exactly two hours old is still uploaded`() = runTest {
        val gateway = gateway()

        gateway.onReport(heard(reportTimeMs = now - TWO_HOURS_MS))
        runCurrent()

        assertEquals(1, uploader.uploads.size)
    }

    // ── 去重 ─────────────────────────────────────────────────────────────────

    @Test
    fun `the same report heard twice is uploaded once`() = runTest {
        val gateway = gateway()
        val report = heard()

        gateway.onReport(report)
        gateway.onReport(heard(reportTimeMs = report.reportTimeMs)) // 經 gossip sync 再收到一次
        runCurrent()

        assertEquals(1, uploader.uploads.size)
    }

    @Test
    fun `an older report of the same Reporter is not uploaded after a newer one`() = runTest {
        val gateway = gateway()

        gateway.onReport(heard(reportTimeMs = now - 60_000))
        gateway.onReport(heard(reportTimeMs = now - 120_000))
        runCurrent()

        assertEquals(listOf(now - 60_000), uploader.uploads.map { it.first.reportTimeMs })
    }

    @Test
    fun `a newer report of the same Reporter is uploaded too`() = runTest {
        val gateway = gateway()

        gateway.onReport(heard(reportTimeMs = now - 120_000, sos = true))
        gateway.onReport(heard(reportTimeMs = now - 60_000, sos = false)) // 撤回 SOS
        runCurrent()

        assertEquals(listOf(true, false), uploader.uploads.map { it.first.payload.sos })
    }

    @Test
    fun `reports of different Reporters are each uploaded`() = runTest {
        val gateway = gateway()

        gateway.onReport(heard(handle = "aaaaaaaaaaaa"))
        gateway.onReport(heard(handle = "bbbbbbbbbbbb"))
        runCurrent()

        assertEquals(listOf("aaaaaaaaaaaa", "bbbbbbbbbbbb"), uploader.uploads.map { it.first.reporterHandle })
    }

    // ── 寫入結果 ─────────────────────────────────────────────────────────────

    @Test
    fun `a refused write counts as uploaded, so the same report is not retried`() = runTest {
        // PERMISSION_DENIED 多半是別的 gateway 已寫入同一份或更新的回報
        uploader.results += UploadResult.PERMISSION_DENIED
        val gateway = gateway()
        val report = heard()

        gateway.onReport(report)
        gateway.onReport(heard(reportTimeMs = report.reportTimeMs))
        runCurrent()

        assertEquals(1, uploader.uploads.size)
    }

    @Test
    fun `a refused write still lets a newer report through`() = runTest {
        uploader.results += UploadResult.PERMISSION_DENIED
        val gateway = gateway()

        gateway.onReport(heard(reportTimeMs = now - 120_000))
        gateway.onReport(heard(reportTimeMs = now - 60_000))
        runCurrent()

        assertEquals(2, uploader.uploads.size)
    }

    @Test
    fun `a report whose upload failed transiently is not recorded as uploaded`() = runTest {
        uploader.results += UploadResult.TRANSIENT_FAILURE
        val gateway = gateway()
        val report = heard()

        gateway.onReport(report)
        gateway.onReport(heard(reportTimeMs = report.reportTimeMs)) // 下次再收到時可以再試
        runCurrent()

        assertEquals(2, uploader.uploads.size)
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private fun TestScope.gateway(uid: String? = GATEWAY_UID, online: Boolean = true): MeshGateway =
        MeshGateway(uploader, nowMs = { now }, scope = backgroundScope).also {
            it.onSignedIn(uid)
            it.onNetworkChanged(online)
            runCurrent()
        }

    private fun heard(
        handle: String = "abcdef012345",
        reportTimeMs: Long = now - 60_000,
        sos: Boolean = true
    ) = GatewayReport(
        payload = HealthReportPayload(handle, HealthStatus.SEVERE, "wsqqqm", reportTimeMs, sos),
        senderPeerID = "0102030405060708",
        rawPacket = byteArrayOf(0x01, 0x30),
        announcement = null
    )

    private class FakeUploader : MeshReportUploader {
        val uploads = mutableListOf<Pair<GatewayReport, String>>()

        /** Answers for the next uploads, in order; UPLOADED once they run out. */
        val results = ArrayDeque<UploadResult>()

        override suspend fun upload(report: GatewayReport, gatewayUid: String): UploadResult {
            uploads += report to gatewayUid
            return results.removeFirstOrNull() ?: UploadResult.UPLOADED
        }
    }

    private companion object {
        const val GATEWAY_UID = "uid-gateway"
        const val TWO_HOURS_MS = 2 * 60 * 60 * 1000L
    }
}
