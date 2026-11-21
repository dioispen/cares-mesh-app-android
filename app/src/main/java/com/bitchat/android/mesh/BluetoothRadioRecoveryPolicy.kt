package com.bitchat.android.mesh

import android.os.DeadObjectException
import com.bitchat.android.util.AppConstants

/**
 * BLE 元件（GATT server／client、掃描、廣播）此刻該不該在跑（P0-1）。
 *
 * 2026-11-18 四機試跑（7.2、12.2）：D 關閉藍牙時 app 沒有察覺，連線表留著 A、B 的殘留連線 28 分鐘，
 * 重新開啟後也沒有重建 GATT、掃描與廣播。[BluetoothConnectionManager] 在藍牙狀態改變、GATT 呼叫
 * 發現 binder 已失效時都問這裡，再依結果啟動或拆掉元件。判斷只看傳進來的狀態，方便在 JVM 上測試。
 */
internal object BluetoothRadioPolicy {

    enum class Action { NONE, START, STOP }

    /**
     * @param running 元件已為這一次藍牙開啟啟動。
     * @param requested mesh 要 BLE 運作：`startServices()` 之後、`disableTransport()`／`stopServices()`
     *   之前。藍牙重新開啟時，debug 開關關掉的傳輸因此不會被打開。
     * @param transportEnabled debug 設定的 BLE 總開關。
     * @param adapterOn 藍牙轉接器此刻是 `STATE_ON`。`TURNING_OFF` 已不算：堆疊還活著，正好趁這時
     *   好好斷線、關閉 GATT。
     * @param faulted GATT 呼叫發現 binder 已失效：手上的 GATT 物件都不能再用，元件要先拆掉，下一次
     *   判斷再依 [adapterOn] 重建。
     */
    fun decide(
        running: Boolean,
        requested: Boolean,
        transportEnabled: Boolean,
        adapterOn: Boolean,
        faulted: Boolean = false
    ): Action {
        val wanted = requested && transportEnabled && adapterOn
        return when {
            running && (faulted || !wanted) -> Action.STOP
            !running && wanted -> Action.START
            else -> Action.NONE
        }
    }
}

/**
 * 一條鏈路的寫入（client write／server notification）沒有被藍牙堆疊接受時怎麼辦（P0-1）。
 *
 * 試跑中 D 的 app 對失效的 GATT 物件每 15 ms 重試一次、永不放棄：藍牙關閉期間記了約 40 萬行
 * binder 錯誤，重新開啟後又有約 13.3 萬次 `DeadObjectException`。重試只留給鏈路暫時忙碌的情況。
 */
internal object LinkSendFailurePolicy {

    enum class Action {
        /** 鏈路暫時忙碌（例如 write-without-response 的緩衝滿了），稍後重試。 */
        RETRY,
        /** 這條鏈路長時間一筆都送不出去：丟掉它的佇列並拆掉鏈路，讓它重新連線。 */
        DROP_LINK,
        /** 藍牙已關閉或 binder 已失效：所有 GATT 物件都不能用了，走藍牙關閉／重建流程。 */
        RESTART_BLUETOOTH
    }

    /**
     * 連續失敗超過這麼久、一筆都沒被接受，就當作鏈路已經不可用。健康但壅塞的鏈路在一兩個連線間隔
     * 內就會恢復；比 Android 預設的 supervision timeout 長，鏈路真的斷了也早就該收到斷線回呼。
     */
    const val STALL_TIMEOUT_MS: Long = 10_000L

    /** 至少要失敗這麼多次才拆鏈路：長時間沒送東西後的第一次失敗不算。 */
    const val MIN_FAILURES_BEFORE_DROP: Int = 20

    /**
     * @param binderDead 這次呼叫拋出的例外（含 cause）是 [DeadObjectException]，見 [isDeadBinder]。
     * @param adapterOn 藍牙轉接器此刻是 `STATE_ON`。舊版 API 會把 binder 錯誤吞掉、只回傳 false，
     *   所以轉接器不是 ON 時被拒也視同藍牙已關閉。
     * @param consecutiveFailures 這條鏈路連續被拒的次數，含這一次。
     * @param failingForMs 從這一串失敗的第一次到現在。
     */
    fun decide(
        binderDead: Boolean,
        adapterOn: Boolean,
        consecutiveFailures: Int,
        failingForMs: Long
    ): Action = when {
        binderDead || !adapterOn -> Action.RESTART_BLUETOOTH
        consecutiveFailures >= MIN_FAILURES_BEFORE_DROP && failingForMs >= STALL_TIMEOUT_MS -> Action.DROP_LINK
        else -> Action.RETRY
    }

    /**
     * Android 13 起 GATT 呼叫遇到失效的 binder 會拋出包著 `DeadSystemException` 的
     * `RuntimeException`，有些版本直接包 [DeadObjectException]；兩者都沿 cause 找得到。
     */
    fun isDeadBinder(error: Throwable?): Boolean =
        generateSequence(error) { it.cause }.take(MAX_CAUSE_DEPTH).any { it is DeadObjectException }

    private const val MAX_CAUSE_DEPTH = 8
}

/**
 * 殭屍連線偵測（P0-2）：鏈路還在連線表上，卻已經收不到任何封包。
 *
 * 試跑中 C（12.1）掛著 2–3 條連線 20 分鐘，`RX`、`DUP` 都是 0，`STAT` 仍列出 A、B、D；對方都斷了
 * 之後，C 自己的斷線回呼又晚了 4 分鐘。這種鏈路要由本機主動斷開，讓它重新連線。
 */
internal object LinkIdlePolicy {

    /**
     * @param lastActivityMs 連上的時間與最後一次收到封包的時間取較晚者。
     * @param nowMs 和 [lastActivityMs] 同一個不含深度睡眠的單調時鐘：本機睡著、計時器被延後時，
     *   睡著的那段不算閒置，醒來後不會把正常的鏈路誤判成殭屍連線。
     */
    fun isIdle(
        lastActivityMs: Long,
        nowMs: Long,
        timeoutMs: Long = AppConstants.Mesh.LINK_IDLE_TIMEOUT_MS
    ): Boolean = nowMs - lastActivityMs > timeoutMs
}
