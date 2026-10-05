package com.bitchat.android.experiment

import android.content.Context
import com.bitchat.android.mesh.PowerManager
import com.bitchat.android.service.MeshServiceHolder

/**
 * 實驗事件需要的 mesh 現況（#70）：本機 peerID、電源模式、直連與它們的 peer、RSSI。
 * 每次都讀當下的值；mesh 還沒建立時回 null 或空清單，事件的那些欄位就留空。
 */
interface MeshProbe {
    fun myPeerID(): String?
    fun powerMode(): String?
    fun linkCount(): Int?
    /** BLE 鏈路 [address] 已確認的對面 peerID。 */
    fun peerAt(address: String): String?
    /** BLE 鏈路 [address] 的連線 RSSI，取得到才有。 */
    fun rssiAt(address: String): Int?
    fun links(): List<Link>

    data class Link(val address: String, val peerID: String?, val rssi: Int?)
}

/** 讀 [MeshServiceHolder] 裡目前的 BLE mesh 與全域 [PowerManager]。 */
class LiveMeshProbe(private val context: Context) : MeshProbe {
    private val connections get() = MeshServiceHolder.meshService?.connectionManager

    override fun myPeerID(): String? = MeshServiceHolder.meshService?.myPeerID

    override fun powerMode(): String =
        PowerManager.getInstance(context).profile.value.mode.name

    override fun linkCount(): Int? = connections?.getConnectedDeviceCount()

    override fun peerAt(address: String): String? = connections?.addressPeerMap?.get(address)

    override fun rssiAt(address: String): Int? =
        connections?.getConnectedDeviceEntries()?.firstOrNull { it.first == address }?.third

    override fun links(): List<MeshProbe.Link> {
        val connections = connections ?: return emptyList()
        return connections.getConnectedDeviceEntries().map { (address, _, rssi) ->
            MeshProbe.Link(address, connections.addressPeerMap[address], rssi)
        }
    }
}
