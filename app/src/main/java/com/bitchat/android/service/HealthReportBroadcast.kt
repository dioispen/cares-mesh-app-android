package com.bitchat.android.service

import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.util.AppConstants

/**
 * 把 Health Report 的 Broadcast Tier 交給 mesh 廣播。bridge 的 `sendHealthReport` 與實驗發送器
 * （#70）共用這組封包組成與送出路徑，只有實驗可以覆寫 TTL。
 */
object HealthReportBroadcast {

    /** [packet] 與 [send] 的預設 TTL。值與取捨寫在 [AppConstants.HEALTH_REPORT_TTL_HOPS]（#14）。 */
    val DEFAULT_TTL: UByte = AppConstants.HEALTH_REPORT_TTL_HOPS

    /** 把 [payload]（已編碼、未加 tag 的 Broadcast Tier）包成由 [senderID] 發出的 HEALTH_REPORT 封包。 */
    fun packet(
        senderID: String,
        payload: ByteArray,
        ttl: UByte = DEFAULT_TTL,
        timestamp: Long = System.currentTimeMillis()
    ): BitchatPacket = BitchatPacket(
        type = MessageType.HEALTH_REPORT.value,
        ttl = ttl,
        senderID = senderID,
        payload = byteArrayOf(BroadcastContentTag.HEALTH_REPORT.value) + payload
    ).copy(timestamp = timestamp.toULong())

    /**
     * 交給 [service] 簽章後廣播。mesh 沒在跑（[service] 為 null、還沒啟動或已停止）時回傳 false：
     * 停止後的 service 不會再送出任何封包。
     */
    fun send(
        service: BluetoothMeshService?,
        payload: ByteArray,
        ttl: UByte = DEFAULT_TTL,
        timestamp: Long = System.currentTimeMillis()
    ): Boolean {
        if (service == null || !service.isStarted()) return false
        service.sendBroadcastPacket(packet(service.myPeerID, payload, ttl, timestamp))
        return true
    }
}
