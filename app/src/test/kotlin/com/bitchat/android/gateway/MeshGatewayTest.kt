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

    // ── 離線暫存與補傳（#112）────────────────────────────────────────────────

    @Test
    fun `a report heard offline is uploaded once the network is back`() = runTest {
        val gateway = gateway(online = false)
        val report = heard()

        gateway.onReport(report)
        runCurrent()
        assertTrue(uploader.uploads.isEmpty())

        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(listOf(report to GATEWAY_UID), uploader.uploads)
    }

    @Test
    fun `only the newest report of each Reporter is held`() = runTest {
        val gateway = gateway(online = false)

        gateway.onReport(heard(handle = "aaaaaaaaaaaa", reportTimeMs = now - 120_000))
        gateway.onReport(heard(handle = "aaaaaaaaaaaa", reportTimeMs = now - 60_000))
        gateway.onReport(heard(handle = "aaaaaaaaaaaa", reportTimeMs = now - 90_000)) // 較慢的 relay 送來的舊回報
        gateway.onReport(heard(handle = "bbbbbbbbbbbb", reportTimeMs = now - 100_000))
        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(
            setOf("aaaaaaaaaaaa" to now - 60_000, "bbbbbbbbbbbb" to now - 100_000),
            uploader.uploads.map { it.first.reporterHandle to it.first.reportTimeMs }.toSet()
        )
        assertEquals(2, uploader.uploads.size)
    }

    @Test
    fun `a held report that is more than two hours old by the time the network is back is not uploaded`() = runTest {
        val gateway = gateway(online = false)
        gateway.onReport(heard(handle = "aaaaaaaaaaaa", reportTimeMs = now - 60_000))
        gateway.onReport(heard(handle = "bbbbbbbbbbbb", reportTimeMs = now - 10_000))
        runCurrent()

        now += TWO_HOURS_MS - 30_000 // a 已超過兩小時，b 還沒有
        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(listOf("bbbbbbbbbbbb"), uploader.uploads.map { it.first.reporterHandle })
    }

    @Test
    fun `at 1000 held reports the oldest one makes room`() = runTest {
        val gateway = gateway(online = false)
        val handles = (0..1000).map { "%012x".format(it) }
        handles.forEachIndexed { i, handle ->
            gateway.onReport(heard(handle = handle, reportTimeMs = now - 1_000_000 + i * 100L))
        }
        runCurrent()

        gateway.onNetworkChanged(true)
        runCurrent()

        val uploaded = uploader.uploads.map { it.first.reporterHandle }
        assertEquals(1000, uploaded.size)
        assertEquals(handles.drop(1).toSet(), uploaded.toSet())
    }

    @Test
    fun `held reports are uploaded when the user signs in`() = runTest {
        val gateway = gateway(online = false)
        val report = heard()
        gateway.onReport(report)
        gateway.onSignedIn(null) // 例如登入憑證失效
        gateway.onNetworkChanged(true)
        runCurrent()
        assertTrue("signed out: nothing is uploaded", uploader.uploads.isEmpty())

        gateway.onSignedIn("uid-again")
        runCurrent()

        assertEquals(listOf(report to "uid-again"), uploader.uploads)
    }

    @Test
    fun `a report heard while signed out is not held`() = runTest {
        val gateway = gateway(uid = null, online = false)

        gateway.onReport(heard())
        gateway.onSignedIn(GATEWAY_UID)
        gateway.onNetworkChanged(true)
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `a transient failure keeps the report held until the next network event`() = runTest {
        uploader.results += UploadResult.TRANSIENT_FAILURE
        val gateway = gateway()
        val report = heard()

        gateway.onReport(report)
        runCurrent()
        assertEquals(1, uploader.uploads.size)

        gateway.onNetworkChanged(false)
        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(listOf(report, report), uploader.uploads.map { it.first })
    }

    @Test
    fun `a transient failure while catching up leaves the rest held for the next network event`() = runTest {
        val gateway = gateway(online = false)
        gateway.onReport(heard(handle = "aaaaaaaaaaaa"))
        gateway.onReport(heard(handle = "bbbbbbbbbbbb"))
        runCurrent()

        uploader.results += UploadResult.TRANSIENT_FAILURE
        gateway.onNetworkChanged(true)
        runCurrent()
        gateway.onNetworkChanged(false)
        gateway.onNetworkChanged(true)
        runCurrent()

        val succeeded = uploader.uploads.drop(1).map { it.first.reporterHandle }
        assertEquals(setOf("aaaaaaaaaaaa", "bbbbbbbbbbbb"), succeeded.toSet())
        assertEquals(2, succeeded.size)
    }

    @Test
    fun `uploaded and refused reports leave the hold for good`() = runTest {
        uploader.results += listOf(UploadResult.UPLOADED, UploadResult.PERMISSION_DENIED)
        val gateway = gateway(online = false)
        gateway.onReport(heard(handle = "aaaaaaaaaaaa"))
        gateway.onReport(heard(handle = "bbbbbbbbbbbb"))
        gateway.onNetworkChanged(true)
        runCurrent()
        assertEquals(2, uploader.uploads.size)

        gateway.onNetworkChanged(false)
        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(2, uploader.uploads.size)
    }

    @Test
    fun `a newer report uploaded live supersedes an older held one of the same Reporter`() = runTest {
        uploader.results += UploadResult.TRANSIENT_FAILURE
        val gateway = gateway()
        gateway.onReport(heard(reportTimeMs = now - 120_000)) // 失敗，留在暫存
        gateway.onReport(heard(reportTimeMs = now - 60_000)) // 撤回 SOS 的新回報，上傳成功
        gateway.onNetworkChanged(false)
        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(listOf(now - 120_000, now - 60_000), uploader.uploads.map { it.first.reportTimeMs })
    }

    @Test
    fun `staying online does not upload the same held report again`() = runTest {
        val gateway = gateway(online = false)
        gateway.onReport(heard())
        gateway.onNetworkChanged(true)
        gateway.onNetworkChanged(true) // 預設網路的能力變動也會再通知一次
        runCurrent()

        assertEquals(1, uploader.uploads.size)
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
