package com.bitchat.android.experiment

import android.content.Context
import com.bitchat.android.flutter.BridgeMethodHandler
import kotlinx.coroutines.CoroutineScope

/**
 * release build 的實機量測工具（#70）：什麼都沒有。recorder 是 [ExperimentRecorder.NoOp]，不輸出
 * `CARES_EXP` log、不建 `exp.csv`、沒有發送器，也不註冊任何 bridge method（Flutter 的實驗畫面在
 * release 本來就不存在）。debug build 的版本在 `src/debug`，兩者的介面必須一致。
 */
object ExperimentTools {
    val recorder: ExperimentRecorder
        get() = ExperimentRecorder.NoOp

    fun install(context: Context) = Unit

    fun onMeshServiceCreated(scope: CoroutineScope) = Unit

    fun onMeshServiceDestroyed() = Unit

    fun bridgeHandlers(): List<BridgeMethodHandler> = emptyList()
}
