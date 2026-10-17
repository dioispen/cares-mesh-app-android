package com.bitchat.android.experiment

import android.content.Context
import com.bitchat.android.mesh.PowerManager
import com.bitchat.android.service.MeshServiceHolder

/**
 * 實驗事件需要的 mesh 現況（#70）：本機 peerID、電源模式、系統省電模式、直連與它們的 peer。
 * RSSI 不在這裡：連線的 RSSI 只在連上時從掃描結果抄一次、之後不會更新，所以改由
 * [ExperimentRecorder.onScanRssi] 取樣。
 * 每次都讀當下的值；mesh 還沒建立時回 null 或空清單，事件的那些欄位就留空。
 */
interface MeshProbe {
    fun myPeerID(): String?
    fun powerMode(): String?
    fun linkCount(): Int?
    /**
     * Android 的系統省電模式是否開著。app 的電源模式（[powerMode]）不看它，但它會限制背景與掃描，
     * 是實驗要記下的干擾因子。
     */
    fun systemPowerSave(): Boolean?
    /** BLE 鏈路 [address] 已確認的對面 peerID。 */
    fun peerAt(address: String): String?
    fun links(): List<Link>

    data class Link(val address: String, val peerID: String?)
}

/** 讀 [MeshServiceHolder] 裡目前的 BLE mesh 與全域 [PowerManager]。 */
class LiveMeshProbe(private val context: Context) : MeshProbe {
    private val connections get() = MeshServiceHolder.meshService?.connectionManager

    override fun myPeerID(): String? = MeshServiceHolder.meshService?.myPeerID

    override fun powerMode(): String =
        PowerManager.getInstance(context).profile.value.mode.name

    override fun linkCount(): Int? = connections?.getConnectedDeviceCount()

    override fun systemPowerSave(): Boolean? =
        (context.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager)?.isPowerSaveMode

    override fun peerAt(address: String): String? = connections?.addressPeerMap?.get(address)

    override fun links(): List<MeshProbe.Link> {
        val connections = connections ?: return emptyList()
        return connections.getConnectedDeviceEntries().map { (address, _, _) ->
            MeshProbe.Link(address, connections.addressPeerMap[address])
        }
    }
}
