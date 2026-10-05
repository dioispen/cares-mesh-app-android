package com.bitchat.android.experiment

import android.content.Context
import com.bitchat.android.flutter.BridgeMethodHandler
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.service.HealthReportBroadcast
import com.bitchat.android.service.MeshServiceHolder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * debug build 的實機量測工具（#70）。release build 有同名、同介面的 no-op 版本（`src/release`），
 * main 的程式只透過這個物件接上：
 * - [recorder]：BLE mesh 插入點用的 recorder，輸出 `CARES_EXP` log 與 `exp.csv`。
 * - [install]：Application 啟動時建立 CSV log 與每 60 s 一次的 `STAT`。
 * - [onMeshServiceCreated]／[onMeshServiceDestroyed]：發送器跑在 `MeshForegroundService` 的 scope。
 * - [bridgeHandlers]：Flutter 現場計數畫面的 bridge method（[ExperimentBridge]）。
 *
 * 發送器只走 mesh（[HealthReportBroadcast]），不寫入 Firestore。
 */
object ExperimentTools {
    private const val STAT_INTERVAL_MS = 60_000L

    private class Installed(
        val context: Context,
        val probe: MeshProbe,
        val rxCounter: ExperimentRxCounter,
        val recorder: ExperimentEventRecorder
    )

    @Volatile
    private var installed: Installed? = null

    @Volatile
    private var sender: ExperimentSender? = null

    /** [install] 之前是 [ExperimentRecorder.NoOp]。 */
    val recorder: ExperimentRecorder
        get() = installed?.recorder ?: ExperimentRecorder.NoOp

    @Synchronized
    fun install(context: Context) {
        if (installed != null) return
        val app = context.applicationContext
        val probe = LiveMeshProbe(app)
        val rxCounter = ExperimentRxCounter(System::currentTimeMillis)
        val log = ExperimentLog(File(app.filesDir, ExperimentLog.FILE_NAME))
        val recorder = ExperimentEventRecorder(log::write, probe, rxCounter)
        installed = Installed(app, probe, rxCounter, recorder)

        CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
            while (isActive) {
                delay(STAT_INTERVAL_MS)
                recorder.recordStat(BatteryReading.read(app))
            }
        }
    }

    @Synchronized
    fun onMeshServiceCreated(scope: CoroutineScope) {
        val tools = installed ?: return
        sender?.stop()
        sender = ExperimentSender(scope, keepAwake = WakeLockKeepAwake(tools.context)) { plan, pts ->
            val payload = HealthReportPayload(plan.handle, plan.status, geohash = "", reportTimeMillis = pts).encode()
            HealthReportBroadcast.send(MeshServiceHolder.meshService, payload, plan.ttl.toUByte(), pts)
        }
    }

    @Synchronized
    fun onMeshServiceDestroyed() {
        sender?.stop()
        sender = null
    }

    /** [install] 之前沒有 handler。 */
    fun bridgeHandlers(): List<BridgeMethodHandler> {
        val tools = installed ?: return emptyList()
        return listOf(ExperimentBridge(tools.probe, tools.rxCounter) { sender })
    }
}

/** 發送器 run 期間持有的 partial wake lock：螢幕關閉後 CPU 仍照排程醒來送出。 */
private class WakeLockKeepAwake(context: Context) : KeepAwake {
    private val wakeLock =
        (context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager)
            .newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "bitchat:experiment-sender")
            .apply { setReferenceCounted(false) }

    override fun acquire(timeoutMs: Long) = wakeLock.acquire(timeoutMs)

    override fun release() {
        if (wakeLock.isHeld) wakeLock.release()
    }
}
