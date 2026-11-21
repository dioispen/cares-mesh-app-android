package com.bitchat.android.service

import android.util.Log
import com.bitchat.android.experiment.ExperimentHandles
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.sync.OwnHealthReportKeeper
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * 什麼時候重發 Reporter 自己最新的 Health Report（ADR-0010）。純函式，不碰時鐘以外的狀態。
 *
 * 舉著 SOS、或 Status 為輕傷／重傷的回報「一直成立」，直到 Reporter 送出下一筆；但每支手機的
 * 同步暫存只保留一筆回報 2 小時（[AppConstants.Sync.HEALTH_REPORT_RETENTION_MS]）。所以這種回報
 * 每 [AppConstants.Sync.STANDING_REPORT_RESEND_INTERVAL_MS] 以新的封包時間戳重新簽章發送一次。
 */
object StandingHealthReport {

    sealed interface Step

    /** 沒有成立中的回報：等 Reporter 送出下一筆。 */
    data object Idle : Step

    /** 在 [atMs]（牆上時鐘）重發 [payload]：原封不動的 Broadcast Tier，`reportTime` 與位置都不更新。 */
    class Resend(val atMs: Long, val payload: ByteArray) : Step

    /** [packet] 的 Broadcast Tier，去掉 content tag，就是 [HealthReportBroadcast.send] 收的 payload。 */
    fun broadcastTier(packet: BitchatPacket): ByteArray? {
        val tagged = packet.payload
        if (packet.type != MessageType.HEALTH_REPORT.value) return null
        if (tagged.isEmpty() || tagged[0] != BroadcastContentTag.HEALTH_REPORT.value) return null
        return tagged.copyOfRange(1, tagged.size)
    }

    /**
     * 舉著 SOS，或 Status 為輕傷、重傷（「未宣告」必定帶 SOS）。實驗 Handle 的回報背後沒有人在等
     * 救援，重發只會干擾下一場量測，所以不算。
     */
    fun isStanding(packet: BitchatPacket): Boolean {
        val report = broadcastTier(packet)?.let(HealthReportPayload::decode) ?: return false
        if (ExperimentHandles.isExperimentHandle(report.reporterHandle)) return false
        return report.sos || report.status == HealthStatus.MINOR || report.status == HealthStatus.SEVERE
    }

    /**
     * 下一步。[latestOwn] 是保存的最新一筆自己的回報（P0-3），每次都重新讀：Reporter 送出新的一筆、
     * 宣告安全，或 panic 清除，都在這裡生效。下次發送排在上一次發送後 [intervalMs]，所以 app 或服務
     * 重啟既不會連發、也不會漏掉一次；手動送出一筆就是重新起算。
     *
     * [resentAtMs] 是這一輪剛重發、保存區可能還沒寫進去的那次。時間戳比 [nowMs] 還新（之後時鐘被
     * 調回去）時當作剛剛才送，否則要等時鐘追上才會再發。
     */
    fun next(
        latestOwn: BitchatPacket?,
        nowMs: Long,
        resentAtMs: Long? = null,
        intervalMs: Long = AppConstants.Sync.STANDING_REPORT_RESEND_INTERVAL_MS
    ): Step {
        if (latestOwn == null || !isStanding(latestOwn)) return Idle
        val payload = broadcastTier(latestOwn) ?: return Idle
        val lastSent = maxOf(minOf(latestOwn.timestamp.toLong(), nowMs), resentAtMs ?: Long.MIN_VALUE)
        return Resend(lastSent + intervalMs, payload)
    }
}

/**
 * 依 [StandingHealthReport] 重發成立中的 Health Report，在 MeshForegroundService 的 scope 裡跑，
 * 不依賴 Flutter 畫面（ADR-0010）。
 *
 * 平時只有一個 delay 等到下次發送，沒有輪詢；保存的回報一變（[changes]：Reporter 送出新的一筆、
 * 這裡自己的重發寫回保存區、panic 清除），就取消等待、從新的那筆重算。發送走
 * [HealthReportBroadcast.send]，照常簽章、flood、放進同步暫存，並經 P0-3 成為新的「最新一筆」。
 *
 * delay 以開機後的 uptime 計，CPU 休眠時不會前進，Doze 下實際間隔可能比設定的長（試跑 12.1）；
 * 每次醒來都用牆上時鐘重算，所以不會因此連發。
 */
class StandingReportRebroadcaster(
    private val latestOwnReport: suspend () -> BitchatPacket?,
    private val send: (payload: ByteArray) -> Boolean,
    private val changes: Flow<Any?>,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val intervalMs: Long = AppConstants.Sync.STANDING_REPORT_RESEND_INTERVAL_MS,
    private val retryMs: Long = SEND_RETRY_MS
) {

    /** 跑到 [scope] 取消為止。[changes] 一開始就有值，所以啟動時馬上依保存的回報排程。 */
    fun start(scope: CoroutineScope): Job = scope.launch {
        changes.collectLatest {
            // The service scope has no handler: an exception would take the whole service down
            try {
                resendWhileStanding()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Standing Health Report re-send stopped until the next report: ${e.message}")
            }
        }
    }

    private suspend fun resendWhileStanding() {
        var resentAt: Long? = null
        while (true) {
            val step = StandingHealthReport.next(latestOwnReport(), nowMs(), resentAt, intervalMs)
            if (step !is StandingHealthReport.Resend) return
            delay(step.atMs - nowMs())
            if (send(step.payload)) {
                resentAt = nowMs()
                Log.i(TAG, "Re-sent the standing Health Report")
            } else {
                // mesh 沒在跑：送不出去，過一陣子再試，不等到下一個 interval
                Log.w(TAG, "Mesh not running; standing Health Report re-send retried later")
                delay(retryMs)
            }
        }
    }

    companion object {
        private const val TAG = "StandingReportResender"

        /** mesh 沒在跑時，隔多久再試一次。只在該發卻送不出去時才有這種喚醒。 */
        const val SEND_RETRY_MS: Long = 5 * 60 * 1000L

        /** 正式的接線：保存區在目前的 mesh service 裡（[MeshServiceHolder]），panic 後會換一個。 */
        fun start(scope: CoroutineScope): Job = StandingReportRebroadcaster(
            latestOwnReport = { MeshServiceHolder.meshService?.let { it.ownHealthReport.latestOwn() } },
            send = { payload -> HealthReportBroadcast.send(MeshServiceHolder.meshService, payload) },
            changes = OwnHealthReportKeeper.changes
        ).start(scope)
    }
}
