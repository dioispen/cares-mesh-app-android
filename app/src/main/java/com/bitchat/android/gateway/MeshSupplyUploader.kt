package com.bitchat.android.gateway

import com.bitchat.android.protocol.SupplyExchangePacket

/**
 * 別人的物資需求／捐贈，這支手機以 Gateway 身分可以代傳的那一筆，由協定層 hook
 * （`VerifiedSupplyExchangeBridge`）在收到當下交出。
 */
class GatewaySupplyPacket(
    val supply: SupplyExchangePacket,
    /** 封包標頭的 senderID：16 個小寫十六進位字元。 */
    val senderPeerID: String,
    /** `PacketIdUtil` 算出的 Packet ID（32 個小寫十六進位字元），也是 Firestore 文件 ID。 */
    val packetId: String,
    /** 收到時的 SUPPLY_EXCHANGE 封包，簽章完整、不含 BLE padding。 */
    val rawPacket: ByteArray,
    /** 封包標頭的 timestamp（發送端建立這筆需求的時間，epoch millis）。 */
    val createdAtMs: Long
)

/** Gateway 唯一的輸出：正式環境是 Firestore，測試用假的。 */
interface MeshSupplyUploader {
    suspend fun upload(packet: GatewaySupplyPacket, gatewayUid: String): UploadResult
}
