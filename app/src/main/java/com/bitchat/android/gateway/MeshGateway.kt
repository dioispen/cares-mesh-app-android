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
 * 輸入只有 [onReport]、[onNetworkChanged]、[onSignedIn]；輸出只有注入的 [uploader]，時鐘也是注入的。
 * 輸入依到達順序在 [scope] 上的單一 coroutine 處理，狀態因此不必上鎖；上傳一筆一筆來。
 * 接 mesh、FirebaseAuth、ConnectivityManager 與 Firestore 的是 [MeshGatewayRuntime]。
 *
 * 上傳條件，全部成立才上傳：
 * 1. 已登入。
 * 2. 回報年齡不超過 [retentionMs]（2 小時，與 Health Report 的保留期限相同）。
 * 3. `reportTime` 比這個 Handle 已上傳過的最新 `reportTime` 更新。
 * 4. 有網路。沒網路時收到的回報直接丟棄。
 */
class MeshGateway(
    private val uploader: MeshReportUploader,
    private val nowMs: () -> Long,
    scope: CoroutineScope,
    private val retentionMs: Long = AppConstants.Sync.HEALTH_REPORT_RETENTION_MS
) {
    private sealed interface Input {
        class Report(val report: GatewayReport) : Input
        class Network(val available: Boolean) : Input
        class Account(val uid: String?) : Input
    }

    private val inputs = Channel<Input>(Channel.UNLIMITED)

    private var online = false
    private var gatewayUid: String? = null

    /**
     * Reporter Handle → 已上傳（或確認已在 Firestore 上）的最新 `reportTime`。只放記憶體：
     * 服務重啟後重傳一次，會被規則以 `reportTime` 未嚴格遞增拒絕，並視同成功。
     */
    private val uploadedReportTimes = HashMap<String, Long>()

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

    /** 不再接受輸入；正在處理的一筆仍會跑完，除非 [scope] 也取消了。 */
    fun stop() {
        inputs.close()
    }

    private suspend fun handle(input: Input) {
        when (input) {
            is Input.Report -> relay(input.report)
            is Input.Network -> online = input.available
            is Input.Account -> gatewayUid = input.uid
        }
    }

    private suspend fun relay(report: GatewayReport) {
        val uid = gatewayUid ?: return
        forgetExpired()
        if (!isFresh(report) || isUploaded(report)) return
        if (!online) return
        upload(report, uid)
    }

    private suspend fun upload(report: GatewayReport, uid: String) {
        when (uploader.upload(report, uid)) {
            UploadResult.UPLOADED -> markUploaded(report)
            UploadResult.PERMISSION_DENIED -> {
                Log.i(TAG, "Firestore refused a relayed report; counting it as already uploaded")
                markUploaded(report)
            }
            UploadResult.TRANSIENT_FAILURE -> Log.w(TAG, "Relayed report not uploaded; dropped")
        }
    }

    private fun isFresh(report: GatewayReport): Boolean = nowMs() - report.reportTimeMs <= retentionMs

    private fun isUploaded(report: GatewayReport): Boolean =
        (uploadedReportTimes[report.reporterHandle] ?: Long.MIN_VALUE) >= report.reportTimeMs

    private fun markUploaded(report: GatewayReport) {
        uploadedReportTimes.merge(report.reporterHandle, report.reportTimeMs) { old, new -> maxOf(old, new) }
    }

    /** 過期的紀錄不必留著：同一個 Handle 之後送來的同樣舊或更舊的回報，本來就因過期而不上傳。 */
    private fun forgetExpired() {
        val oldestFresh = nowMs() - retentionMs
        uploadedReportTimes.values.removeAll { it < oldestFresh }
    }

    private companion object {
        const val TAG = "MeshGateway"
    }
}
