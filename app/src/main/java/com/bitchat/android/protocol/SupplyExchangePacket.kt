package com.bitchat.android.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** 物資封包的動作：要求物資（request）或捐贈物資（offer）。 */
enum class SupplyExchangeAction(val wire: Byte, val value: String) {
    REQUEST(1, "request"),
    OFFER(2, "offer");

    companion object {
        fun fromWire(value: Byte): SupplyExchangeAction? = values().firstOrNull { it.wire == value }
        fun fromValue(value: String): SupplyExchangeAction? = values().firstOrNull { it.value == value }
    }
}

/**
 * SUPPLY_EXCHANGE（0x32）的 payload：一筆物資需求或捐贈，不含任何可識別個人的欄位。
 *
 * 線路格式（big-endian，最大 [MAX_ENCODED_SIZE] bytes）：
 * ```
 *   [0]        version       1 byte    目前為 VERSION；未知版本一律拒收
 *   [1]        action        1 byte    SupplyExchangeAction.wire
 *   [2..17]    exchangeId    16 bytes  這筆需求／捐贈的隨機 ID（UUID）
 *   [18..19]   itemIdLen     2 bytes   接著 itemIdLen bytes 的 UTF-8 物資型錄 ID
 *   [..]       itemNameLen   2 bytes   接著 itemNameLen bytes 的 UTF-8 品名快照
 *   [..]       quantity      4 bytes   unsigned，必須 ≥ 1
 *   [..]       unitLen       1 byte    接著 unitLen bytes 的 UTF-8 單位
 * ```
 *
 * [exchangeId] 由發送端的 App 產生，與它自己寫進 Firestore `supply_requests`／`supply_pledges`
 * 的文件 ID 相同：管理後台拿它把 Gateway 代傳的 `mesh_supply_packets` 與 Reporter 本人有網路時
 * 上傳的那一筆對起來，不會算成兩筆。它是隨機值，不能反推回帳號。
 *
 * 封包標頭的 timestamp 是建立時間。與 Dart 端 `supply_exchange_packet.dart` 共用同一組權威向量
 * （`SupplyExchangePacketTest`、`supply_exchange_packet_test.dart`）。
 */
data class SupplyExchangePacket(
    val action: SupplyExchangeAction,
    /** 32 個小寫十六進位字元（16 bytes）。 */
    val exchangeId: String,
    val itemId: String,
    val itemName: String,
    val quantity: Long,
    val unit: String
) {
    fun encode(): ByteArray {
        require(EXCHANGE_ID_REGEX.matches(exchangeId)) { "exchangeId 必須是 ${EXCHANGE_ID_BYTES * 2} 個十六進位字元" }
        val idBytes = hexToBytes(exchangeId)
        val itemIdBytes = encodeText(itemId, MAX_ITEM_ID_BYTES, "itemId")
        val itemNameBytes = encodeText(itemName, MAX_ITEM_NAME_BYTES, "itemName")
        val unitBytes = encodeText(unit, MAX_UNIT_BYTES, "unit")
        require(quantity in 1..MAX_QUANTITY) { "quantity 必須是 1..$MAX_QUANTITY" }

        return ByteBuffer.allocate(
            1 + 1 + EXCHANGE_ID_BYTES + 2 + itemIdBytes.size + 2 + itemNameBytes.size + 4 + 1 + unitBytes.size
        ).order(ByteOrder.BIG_ENDIAN).apply {
            put(VERSION.toByte())
            put(action.wire)
            put(idBytes)
            putShort(itemIdBytes.size.toShort())
            put(itemIdBytes)
            putShort(itemNameBytes.size.toShort())
            put(itemNameBytes)
            putInt(quantity.toInt())
            put(unitBytes.size.toByte())
            put(unitBytes)
        }.array()
    }

    companion object {
        const val VERSION = 1
        const val EXCHANGE_ID_BYTES = 16
        const val MAX_ITEM_ID_BYTES = 64
        const val MAX_ITEM_NAME_BYTES = 96
        const val MAX_UNIT_BYTES = 16
        const val MAX_QUANTITY = 0xFFFF_FFFFL

        /** 1 + 1 + exchangeId + (2 + itemId) + (2 + itemName) + quantity + (1 + unit)。 */
        const val MAX_ENCODED_SIZE =
            1 + 1 + EXCHANGE_ID_BYTES + 2 + MAX_ITEM_ID_BYTES + 2 + MAX_ITEM_NAME_BYTES + 4 + 1 + MAX_UNIT_BYTES

        /** 最短的合法 payload：三個字串各 1 byte。 */
        private const val MIN_ENCODED_SIZE = 1 + 1 + EXCHANGE_ID_BYTES + 2 + 1 + 2 + 1 + 4 + 1 + 1

        val EXCHANGE_ID_REGEX = Regex("[0-9a-fA-F]{${EXCHANGE_ID_BYTES * 2}}")

        /** 由 bridge 的 Map 建構；欄位缺少或型別不對回傳 null。 */
        fun fromMap(values: Map<*, *>): SupplyExchangePacket? {
            val action = (values["action"] as? String)?.let(SupplyExchangeAction::fromValue) ?: return null
            val exchangeId = (values["exchangeId"] as? String)?.lowercase() ?: return null
            if (!EXCHANGE_ID_REGEX.matches(exchangeId)) return null
            val itemId = values["itemId"] as? String ?: return null
            val itemName = values["itemName"] as? String ?: return null
            val quantity = (values["quantity"] as? Number)?.toLong() ?: return null
            val unit = values["unit"] as? String ?: return null
            return SupplyExchangePacket(action, exchangeId, itemId, itemName, quantity, unit)
        }

        /** 解碼失敗（未知版本、長度不符、字串非法、數量為 0、尾端多餘 bytes）一律回傳 null。 */
        fun decode(bytes: ByteArray): SupplyExchangePacket? {
            return try {
                if (bytes.size < MIN_ENCODED_SIZE || bytes.size > MAX_ENCODED_SIZE) return null
                val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
                if ((buffer.get().toInt() and 0xFF) != VERSION) return null
                val action = SupplyExchangeAction.fromWire(buffer.get()) ?: return null
                val idBytes = ByteArray(EXCHANGE_ID_BYTES)
                buffer.get(idBytes)
                val itemId = buffer.readText(MAX_ITEM_ID_BYTES) ?: return null
                val itemName = buffer.readText(MAX_ITEM_NAME_BYTES) ?: return null
                if (buffer.remaining() < 4 + 1) return null
                val quantity = buffer.int.toLong() and 0xFFFF_FFFFL
                if (quantity == 0L) return null
                val unitLength = buffer.get().toInt() and 0xFF
                if (unitLength !in 1..MAX_UNIT_BYTES || buffer.remaining() != unitLength) return null
                val unit = buffer.readUtf8(unitLength) ?: return null
                SupplyExchangePacket(action, bytesToHex(idBytes), itemId, itemName, quantity, unit)
            } catch (_: java.nio.BufferUnderflowException) {
                null
            }
        }

        private fun ByteBuffer.readText(maxBytes: Int): String? {
            if (remaining() < 2) return null
            val length = short.toInt() and 0xFFFF
            if (length !in 1..maxBytes || remaining() < length) return null
            return readUtf8(length)
        }

        private fun ByteBuffer.readUtf8(length: Int): String? {
            val bytes = ByteArray(length)
            get(bytes)
            return try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString()
                    .takeIf { it.isNotBlank() }
            } catch (_: CharacterCodingException) {
                null
            }
        }

        private fun encodeText(value: String, maxBytes: Int, field: String): ByteArray {
            val bytes = value.toByteArray(Charsets.UTF_8)
            require(value.isNotBlank() && bytes.size <= maxBytes) {
                "$field 必須非空白且不超過 $maxBytes 個 UTF-8 bytes"
            }
            return bytes
        }

        private fun hexToBytes(hex: String): ByteArray =
            ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

        private fun bytesToHex(bytes: ByteArray): String =
            bytes.joinToString("") { "%02x".format(it) }
    }
}
