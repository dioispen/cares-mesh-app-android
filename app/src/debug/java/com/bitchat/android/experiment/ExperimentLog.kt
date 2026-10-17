package com.bitchat.android.experiment

import android.util.Log
import java.io.File
import java.io.IOException
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * 實驗事件的輸出（#70）：每個事件一行，寫進 logcat（tag [TAG]）並 append 到 [file]（app 私有目錄的
 * `exp.csv`）。logcat 是 ring buffer，長時間實驗會被沖掉，分析以 CSV 為準：
 * `adb shell run-as com.bitchat.droid cat files/exp.csv`。
 *
 * [write] 只把工作排進單一背景 [writer]，不在封包處理路徑上做 I/O；同一個 writer 依序處理，
 * 列的順序就是 [write] 的順序。新檔（或空檔）先寫一行 [ExperimentEvent.CSV_HEADER]。
 */
class ExperimentLog(
    private val file: File,
    private val writer: Executor = Executors.newSingleThreadExecutor { Thread(it, "cares-exp-writer") },
    private val logcat: (String) -> Unit = { Log.i(TAG, it) }
) {
    fun write(event: ExperimentEvent) {
        writer.execute {
            val row = event.toCsvRow()
            logcat(row)
            append(row)
        }
    }

    private fun append(row: String) {
        try {
            val needsHeader = !file.exists() || file.length() == 0L
            file.appendText(if (needsHeader) "${ExperimentEvent.CSV_HEADER}\n$row\n" else "$row\n")
        } catch (e: IOException) {
            Log.w(TAG, "無法寫入 ${file.name}: ${e.message}")
        }
    }

    companion object {
        const val TAG = "CARES_EXP"
        const val FILE_NAME = "exp.csv"
    }
}
