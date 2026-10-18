package com.bitchat.android.experiment

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager

/** `STAT` 的電量與電池溫度；讀不到的留 null。 */
data class BatteryReading(val percent: Int?, val temperatureC: Double?) {
    companion object {
        /** 讀 sticky 的 `ACTION_BATTERY_CHANGED`，不註冊 receiver。 */
        fun read(context: Context): BatteryReading {
            val intent = try {
                context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            } catch (_: Exception) {
                null
            } ?: return BatteryReading(null, null)
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            val tenthsC = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            return BatteryReading(
                percent = if (level >= 0 && scale > 0) level * 100 / scale else null,
                temperatureC = if (tenthsC != Int.MIN_VALUE) tenthsC / 10.0 else null
            )
        }
    }
}
