package com.bitchat.android.service

import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType

object SupplyExchangeBroadcast {
    const val DEFAULT_TTL: UByte = 7u

    fun packet(
        senderID: String,
        payload: ByteArray,
        timestamp: Long = System.currentTimeMillis()
    ): BitchatPacket = BitchatPacket(
        type = MessageType.SUPPLY_EXCHANGE.value,
        ttl = DEFAULT_TTL,
        senderID = senderID,
        payload = payload
    ).copy(timestamp = timestamp.toULong())

    fun send(service: BluetoothMeshService?, payload: ByteArray): Boolean {
        if (service == null || !service.isStarted()) return false
        service.sendBroadcastPacket(packet(service.myPeerID, payload))
        return true
    }
}
