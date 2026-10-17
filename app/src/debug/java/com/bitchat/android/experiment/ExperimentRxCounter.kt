package com.bitchat.android.experiment

/**
 * 現場計數畫面的 `RX` 計數（#70）：最近收到的實驗 Health Report，依實驗 handle 分。
 * 只保留 [MAX_WINDOW_MS] 內的到達紀錄。
 */
class ExperimentRxCounter(private val clock: () -> Long) {
    private val arrivals = ArrayDeque<Arrival>()

    /** 目前保留的到達紀錄數。 */
    val size: Int
        @Synchronized get() = arrivals.size

    @Synchronized
    fun record(handle: String, atMs: Long) {
        arrivals.addLast(Arrival(handle, atMs))
        forgetOlderThan(clock())
    }

    /** 最近 [windowMs]（不含剛好滿 [windowMs] 前那一刻）內各 handle 的到達數；沒有到達的 handle 不列。 */
    @Synchronized
    fun countsWithin(windowMs: Long): Map<String, Int> {
        val now = clock()
        forgetOlderThan(now)
        return arrivals.filter { it.atMs > now - windowMs }.groupingBy { it.handle }.eachCount()
    }

    private fun forgetOlderThan(now: Long) {
        while (arrivals.isNotEmpty() && arrivals.first().atMs <= now - MAX_WINDOW_MS) {
            arrivals.removeFirst()
        }
    }

    private data class Arrival(val handle: String, val atMs: Long)

    companion object {
        const val MAX_WINDOW_MS = 60_000L
    }
}
