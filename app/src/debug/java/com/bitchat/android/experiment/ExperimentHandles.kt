package com.bitchat.android.experiment

/** 實驗發送器的固定 reporter handle：第 N 支手機用 `ee000000000N`（N = 1..7）。 */
object ExperimentHandles {
    val DEVICES = 1..7

    fun forDevice(device: Int): String {
        require(device in DEVICES) { "device 必須在 $DEVICES" }
        return "ee" + device.toString().padStart(10, '0')
    }

    private val all = DEVICES.map(::forDevice).toSet()

    fun isExperimentHandle(handle: String): Boolean = handle in all
}
