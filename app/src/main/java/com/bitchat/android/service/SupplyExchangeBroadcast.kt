package com.bitchat.android.service

import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType

/**
 * 把一筆物資需求／捐贈（已編碼的 [com.bitchat.android.protocol.SupplyExchangePacket]）交給 mesh 廣播。
 * 與 [HealthReportBroadcast] 同一條送出路徑：由 service 簽章、廣播、登記進 gossip sync。
 */
object SupplyExchangeBroadcast {

    /**
     * 與 Health Report 相同的 TTL：物資需求不該比求救傳得更遠、更積極（`ttl >= 4` 的前幾跳會無條件轉傳，
     * 見 PacketRelayManager）。要改屬於 #14，不在這裡改。
     */
    val DEFAULT_TTL: UByte = HealthReportBroadcast.DEFAULT_TTL

    fun packet(
        senderID: String,
        payload: ByteArray,
        ttl: UByte = DEFAULT_TTL,
        timestamp: Long = System.currentTimeMillis()
    ): BitchatPacket = BitchatPacket(
        type = MessageType.SUPPLY_EXCHANGE.value,
        ttl = ttl,
        senderID = senderID,
        payload = payload
    ).copy(timestamp = timestamp.toULong())

    /** mesh 沒在跑（[service] 為 null、還沒啟動或已停止）時回傳 false，不送出任何封包。 */
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
