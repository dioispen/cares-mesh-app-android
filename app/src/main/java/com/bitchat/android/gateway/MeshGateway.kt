package com.bitchat.android.gateway

import android.util.Log
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * Gateway（ADR-0009）：已登入、有網路的手機，把經 mesh 收到、驗證通過的別人的 Health Report，
 * 原樣的 Broadcast Tier 寫進 Firestore 的 `mesh_reports/{reporterHandle}`。每個 Reporter Handle
 * 一份，只保留最新的。
 *
 * 輸入只有 [onReport]、[onNetworkChanged]、[onSignedIn]、[onEnabledChanged]；輸出只有注入的
 * [uploader]，時鐘也是注入的。輸入依到達順序在 [scope] 上的單一 coroutine 處理，狀態因此不必上鎖；
 * 上傳一筆一筆來。接 mesh、FirebaseAuth、ConnectivityManager、設定與 Firestore 的是 [MeshGatewayRuntime]。
 *
 * 上傳條件，全部成立才上傳：
 * 1. 使用者沒有關閉代傳（#113，預設開啟）。關閉時不上傳也不暫存，已暫存的一併清除。
 * 2. 已登入。未登入時收到的回報直接丟棄，不暫存。
 * 3. 回報年齡不超過 [retentionMs]（2 小時，與 Health Report 的保留期限相同）。
 * 4. `reportTime` 比這個 Handle 已上傳過的最新 `reportTime` 更新。
 *
 * 有網路就立即上傳；沒網路、或上傳遇到暫時性錯誤時，先放進暫存（#112），等網路恢復或使用者
 * 登入時補傳，讓手機能扮演「從災區帶著回報走出來」的角色。暫存只收經過協定層 hook 的回報，
 * 不讀 gossip sync 的保留集合，所以補傳的都通過驗證與實驗 Handle 過濾。登出只是暫停補傳，
 * 不清掉暫存：暫存本來就只放記憶體，兩小時內過期。
 */
class MeshGateway(
    private val uploader: MeshReportUploader,
    private val nowMs: () -> Long,
    scope: CoroutineScope,
    private val retentionMs: Long = AppConstants.Sync.HEALTH_REPORT_RETENTION_MS,
    private val maxHeldReports: Int = MAX_HELD_REPORTS
) {
    private sealed interface Input {
        class Report(val report: GatewayReport) : Input
        class Network(val available: Boolean) : Input
        class Account(val uid: String?) : Input
        class Enabled(val enabled: Boolean) : Input
    }

    private val inputs = Channel<Input>(Channel.UNLIMITED)

    private var enabled = true
    private var online = false
    private var gatewayUid: String? = null

    /**
     * Reporter Handle → 已上傳（或確認已在 Firestore 上）的最新 `reportTime`。只放記憶體：
     * 服務重啟後重傳一次，會被規則以 `reportTime` 未嚴格遞增拒絕，並視同成功。
     */
    private val uploadedReportTimes = HashMap<String, Long>()

    /**
     * 等著上傳的回報：Reporter Handle → `reportTime` 最新的一份。只放記憶體、不寫磁碟，
     * 過期就剔除，最多 [maxHeldReports] 筆，滿了剔除最舊的。
     */
    private val held = HashMap<String, GatewayReport>()

    init {
        scope.launch {
            for (input in inputs) handle(input)
        }
    }

    /** 經協定層 hook 收到、驗證通過的回報。 */
    fun onReport(report: GatewayReport) {
        inputs.trySend(Input.Report(report))
    }

    /** 預設網路是否具備 INTERNET 與 VALIDATED。 */
    fun onNetworkChanged(available: Boolean) {
        inputs.trySend(Input.Network(available))
    }

    /** 登入的 uid；登出時為 null。 */
    fun onSignedIn(uid: String?) {
        inputs.trySend(Input.Account(uid))
    }

    /** 設定裡的「代傳附近的求救與回報」（#113）。 */
    fun onEnabledChanged(enabled: Boolean) {
        inputs.trySend(Input.Enabled(enabled))
    }

    /** 不再接受輸入；正在處理的一筆仍會跑完，除非 [scope] 也取消了。 */
    fun stop() {
        inputs.close()
    }

    private suspend fun handle(input: Input) {
        when (input) {
            is Input.Report -> relay(input.report)
            is Input.Network -> {
                val reconnected = input.available && !online
                online = input.available
                // 預設網路的能力每有變動就會通知一次；只有剛連上才補傳。
                if (reconnected) catchUp()
            }
            is Input.Account -> {
                gatewayUid = input.uid
                if (input.uid != null) catchUp()
            }
            is Input.Enabled -> {
                enabled = input.enabled
                // 關閉就是不再替別人保管：已暫存的回報一併清除。重新開啟後，之後收到的才代傳。
                if (enabled) catchUp() else held.clear()
            }
        }
    }

    private suspend fun relay(report: GatewayReport) {
        if (!enabled) return
        val uid = gatewayUid ?: return
        forgetExpired()
        if (!isFresh(report) || isUploaded(report)) return
        if (online) upload(report, uid) else hold(report)
    }

    /** 依 `reportTime` 由舊到新逐筆補傳；遇到暫時性錯誤就停，其餘留到下一次網路事件。 */
    private suspend fun catchUp() {
        val uid = gatewayUid ?: return
        if (!enabled || !online) return
        forgetExpired()
        for (report in held.values.sortedBy { it.reportTimeMs }) {
            if (!upload(report, uid)) break
        }
    }

    /** 回傳是否該繼續上傳下一筆。 */
    private suspend fun upload(report: GatewayReport, uid: String): Boolean {
        when (uploader.upload(report, uid)) {
            UploadResult.UPLOADED -> markUploaded(report)
            UploadResult.PERMISSION_DENIED -> {
                Log.i(TAG, "Firestore refused a relayed report; counting it as already uploaded")
                markUploaded(report)
            }
            UploadResult.TRANSIENT_FAILURE -> {
                Log.w(TAG, "Relayed report not uploaded; held for the next network event")
                hold(report)
                return false
            }
        }
        return true
    }

    private fun hold(report: GatewayReport) {
        val current = held[report.reporterHandle]
        if (current != null && current.reportTimeMs >= report.reportTimeMs) return
        held[report.reporterHandle] = report
        if (held.size > maxHeldReports) {
            held.values.minByOrNull { it.reportTimeMs }?.let { held.remove(it.reporterHandle) }
        }
    }

    private fun isFresh(report: GatewayReport): Boolean = nowMs() - report.reportTimeMs <= retentionMs

    private fun isUploaded(report: GatewayReport): Boolean =
        (uploadedReportTimes[report.reporterHandle] ?: Long.MIN_VALUE) >= report.reportTimeMs

    /** 已上傳的回報，連同同一個 Handle 暫存中同樣舊或更舊的那份，都不必再傳。 */
    private fun markUploaded(report: GatewayReport) {
        uploadedReportTimes.merge(report.reporterHandle, report.reportTimeMs) { old, new -> maxOf(old, new) }
        if ((held[report.reporterHandle]?.reportTimeMs ?: Long.MAX_VALUE) <= report.reportTimeMs) {
            held.remove(report.reporterHandle)
        }
    }

    /**
     * 剔除過期的暫存，也忘掉過期的上傳紀錄：同一個 Handle 之後送來的同樣舊或更舊的回報，
     * 本來就因過期而不上傳。
     */
    private fun forgetExpired() {
        val oldestFresh = nowMs() - retentionMs
        held.values.removeAll { it.reportTimeMs < oldestFresh }
        uploadedReportTimes.values.removeAll { it < oldestFresh }
    }

    private companion object {
        const val TAG = "MeshGateway"

        /** 比照 Health Report 驗簽 key 快取的上限（AppConstants.Sync.MAX_HEALTH_REPORT_SIGNING_KEYS）。 */
        const val MAX_HELD_REPORTS = 1_000
    }
}
