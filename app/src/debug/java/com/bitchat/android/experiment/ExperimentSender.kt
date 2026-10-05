package com.bitchat.android.experiment

import com.bitchat.android.protocol.HealthStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/** 實驗發送器一次 run 的參數（#70）。 */
data class ExperimentPlan(
    /** 這支手機的實驗 handle（[ExperimentHandles]）。 */
    val handle: String,
    val status: HealthStatus,
    /** 要送幾筆。 */
    val count: Int,
    /** 兩筆之間隔幾 ms；0 是突發測試，一次送完。 */
    val intervalMs: Long,
    /** 3（現行 Health Report）或 7（`MESSAGE_TTL_HOPS`）。 */
    val ttl: Int,
    /** 牆鐘開始時間，讓多支手機同時開始；null 是立刻開始。 */
    val startAt: LocalTime?
) {
    companion object {
        val TTLS = setOf(3, 7)
    }
}

/** run 進行期間讓 CPU 保持喚醒（螢幕關閉也照常送，E4 需要）。 */
interface KeepAwake {
    /** [timeoutMs] 是保險：就算沒呼叫 [release]，時間到也會放掉。 */
    fun acquire(timeoutMs: Long)
    fun release()

    object None : KeepAwake {
        override fun acquire(timeoutMs: Long) = Unit
        override fun release() = Unit
    }
}

/**
 * 實驗用自動發送器（#70）：依 [ExperimentPlan] 在指定的牆鐘時刻開始，定速送出固定筆數的
 * Health Report。迴圈跑在 [scope]（`MeshForegroundService` 的 scope）裡，所以 app 進背景後仍繼續；
 * 等待與送出期間持有 [keepAwake]。
 *
 * 第 i 筆排在 `開始時刻 + i × 間隔`，不因單筆送出花的時間累積誤差。每筆交給 [transmit] 的封包
 * timestamp `pts` 嚴格遞增（突發時同一 ms 會順延 1 ms），`(src, pts)` 因此唯一。
 *
 * 廣播沒有回條，送出端無從得知誰收到；最接近的本機訊號是 BLE 實際寫出了幾條鏈路，由
 * [onWritten] 回報，計入 [Status.written]／[Status.noLink]。
 */
class ExperimentSender(
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: ZoneId = ZoneId.systemDefault(),
    private val keepAwake: KeepAwake = KeepAwake.None,
    /** 送出一筆；mesh 沒收下時回傳 false（算進 [Status.failed]）。 */
    private val transmit: (plan: ExperimentPlan, pts: Long) -> Boolean
) {
    enum class State { IDLE, WAITING, SENDING, DONE, STOPPED }

    data class Status(
        val state: State,
        val plan: ExperimentPlan? = null,
        val startsAtMs: Long? = null,
        /** 交給 mesh 的筆數。 */
        val sent: Int = 0,
        /** mesh 沒收下（例如服務沒在跑）的筆數。 */
        val failed: Int = 0,
        /** 已送出、且至少寫出一條 BLE 鏈路的筆數。 */
        val written: Int = 0,
        /** 已送出、但寫出時沒有任何鏈路可送（沒有人收得到）的筆數。 */
        val noLink: Int = 0
    ) {
        val total: Int get() = plan?.count ?: 0
        val isRunning: Boolean get() = state == State.WAITING || state == State.SENDING
    }

    sealed interface StartResult {
        data class Started(val status: Status) : StartResult
        data object AlreadyRunning : StartResult
    }

    private val lock = Any()
    private var current = Status(State.IDLE)
    private var job: Job? = null
    /** 每次 [start] 加一；舊迴圈只能更新自己那一輪的狀態。 */
    private var runId = 0
    /** 本輪已交給 mesh、還沒回報寫出結果的封包 timestamp。 */
    private val awaitingWrite = mutableSetOf<Long>()

    val status: Status get() = synchronized(lock) { current }

    fun start(plan: ExperimentPlan): StartResult = synchronized(lock) {
        if (current.isRunning) return StartResult.AlreadyRunning
        val now = clock()
        val startsAt = resolveStart(now, plan.startAt)
        val run = Status(State.WAITING, plan, startsAt)
        current = run
        awaitingWrite.clear()
        val id = ++runId
        job = scope.launch { send(id, plan, startsAt, now) }
        StartResult.Started(run)
    }

    fun stop(): Status = synchronized(lock) {
        job?.cancel()
        job = null
        if (current.isRunning) current = current.copy(state = State.STOPPED)
        current
    }

    private suspend fun send(id: Int, plan: ExperimentPlan, startsAt: Long, startedAt: Long) {
        keepAwake.acquire(startsAt - startedAt + (plan.count - 1) * plan.intervalMs + WAKE_LOCK_MARGIN_MS)
        try {
            var lastPts = Long.MIN_VALUE
            for (i in 0 until plan.count) {
                delayUntil(startsAt + i * plan.intervalMs)
                if (plan.intervalMs == 0L && i > 0) yield()
                val pts = maxOf(clock(), lastPts + 1)
                lastPts = pts
                // Registered before transmitting: the write can be reported before transmit returns.
                synchronized(lock) { if (id == runId) awaitingWrite += pts }
                val accepted = transmit(plan, pts)
                if (!accepted) synchronized(lock) { awaitingWrite -= pts }
                update(id) {
                    it.copy(
                        state = State.SENDING,
                        sent = it.sent + if (accepted) 1 else 0,
                        failed = it.failed + if (accepted) 0 else 1
                    )
                }
            }
            update(id) { it.copy(state = State.DONE) }
        } finally {
            keepAwake.release()
        }
    }

    /**
     * BLE 寫出了本輪的封包 [pts]，交給 [fanout] 條鏈路（0 表示沒有鏈路）。每筆只算一次；不是本輪
     * 送出的忽略。run 結束後才回報的也照算（最後一筆通常如此）。
     */
    fun onWritten(pts: Long, fanout: Int) = synchronized(lock) {
        if (!awaitingWrite.remove(pts)) return@synchronized
        current = if (fanout > 0) current.copy(written = current.written + 1) else current.copy(noLink = current.noLink + 1)
    }

    private suspend fun delayUntil(atMs: Long) {
        val wait = atMs - clock()
        if (wait > 0) delay(wait)
    }

    /** 只更新第 [id] 輪：[stop] 之後或新的一輪開始後，舊迴圈的更新一律作廢。 */
    private fun update(id: Int, change: (Status) -> Status) = synchronized(lock) {
        if (id == runId && current.isRunning) current = change(current)
    }

    /** [startAt] 的下一次出現：今天還沒到就是今天，已經過了就是明天。 */
    private fun resolveStart(now: Long, startAt: LocalTime?): Long {
        if (startAt == null) return now
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val candidate = today.atTime(startAt).atZone(zone)
        val start = if (candidate.toInstant().toEpochMilli() < now) candidate.plusDays(1) else candidate
        return start.toInstant().toEpochMilli()
    }

    companion object {
        /** wake lock 的 timeout 在預計結束時間之外多留的時間。 */
        const val WAKE_LOCK_MARGIN_MS = 60_000L
    }
}
