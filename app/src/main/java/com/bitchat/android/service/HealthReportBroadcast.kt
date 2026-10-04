package com.bitchat.android.service

import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.MessageType

/**
 * 把 Health Report 的 Broadcast Tier 交給 mesh 廣播。bridge 的 `sendHealthReport` 與實驗發送器
 * （#70）共用這組封包組成與送出路徑，只有實驗可以覆寫 TTL。
 */
object HealthReportBroadcast {

    /** 現行 Health Report 的 TTL。要不要改屬於 #14，不在這裡改。 */
    val DEFAULT_TTL: UByte = 3u

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

    /** 交給 [service] 簽章後廣播；mesh 沒在跑（[service] 為 null）時回傳 false。 */
    fun send(
        service: BluetoothMeshService?,
        payload: ByteArray,
        ttl: UByte = DEFAULT_TTL,
        timestamp: Long = System.currentTimeMillis()
    ): Boolean {
        if (service == null) return false
        service.sendBroadcastPacket(packet(service.myPeerID, payload, ttl, timestamp))
        return true
    }
}
