package com.bitchat.android.experiment

/**
 * 實驗發送器的固定 reporter handle：第 N 支手機用 `ee` 加 N 補零成 10 位（`ee0000000001`～`ee0000000010`）。
 *
 * 放在 main 而不是 debug：發送器只在 debug build，但每個 build 都要認得這些 handle，收到時照常轉發、
 * 不當成真的 Health Report 顯示（`MessageHandler.handleHealthReport`）。真的 handle 是隨機 6 bytes，
 * 撞上這 10 個的機率可以忽略。
 */
object ExperimentHandles {
    val DEVICES = 1..10

    fun forDevice(device: Int): String {
        require(device in DEVICES) { "device 必須在 $DEVICES" }
        return "ee" + device.toString().padStart(10, '0')
    }

    private val all = DEVICES.map(::forDevice).toSet()

    fun isExperimentHandle(handle: String): Boolean = handle in all
}
