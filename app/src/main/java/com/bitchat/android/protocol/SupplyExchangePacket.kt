package com.bitchat.android.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

enum class SupplyExchangeAction(val wire: Byte, val value: String) {
    REQUEST(1, "request"),
    OFFER(2, "offer");

    companion object {
        fun fromWire(value: Byte): SupplyExchangeAction? = values().firstOrNull { it.wire == value }
        fun fromValue(value: String): SupplyExchangeAction? = values().firstOrNull { it.value == value }
    }
}

/**
 * Versioned, PII-free payload for one mesh supply request or offer.
 *
 * Wire format (big-endian): version, action, UTF-8 item ID length and value,
 * UTF-8 item name length and value, unsigned quantity, then UTF-8 unit length
 * and value. The packet header timestamp is the event creation time.
 */
data class SupplyExchangePacket(
    val action: SupplyExchangeAction,
    val itemId: String,
    val itemName: String,
    val quantity: Long,
    val unit: String
) {
    fun encode(): ByteArray {
        val itemIdBytes = encodeText(itemId, MAX_ITEM_ID_BYTES, "itemId")
        val itemNameBytes = encodeText(itemName, MAX_ITEM_NAME_BYTES, "itemName")
        val unitBytes = encodeText(unit, MAX_UNIT_BYTES, "unit")
        require(quantity in 1..MAX_QUANTITY) { "quantity must be a positive uint32" }

        return ByteBuffer.allocate(
            1 + 1 + 2 + itemIdBytes.size + 2 + itemNameBytes.size + 4 + 1 + unitBytes.size
        ).order(ByteOrder.BIG_ENDIAN).apply {
            put(VERSION.toByte())
            put(action.wire)
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
        const val MAX_ITEM_ID_BYTES = 128
        const val MAX_ITEM_NAME_BYTES = 256
        const val MAX_UNIT_BYTES = 64
        const val MAX_QUANTITY = 0xFFFF_FFFFL

        fun fromMap(values: Map<*, *>): SupplyExchangePacket? {
            val action = (values["action"] as? String)?.let(SupplyExchangeAction::fromValue) ?: return null
            val itemId = values["itemId"] as? String ?: return null
            val itemName = values["itemName"] as? String ?: return null
            val quantity = (values["quantity"] as? Number)?.toLong() ?: return null
            val unit = values["unit"] as? String ?: return null
            return SupplyExchangePacket(action, itemId, itemName, quantity, unit)
        }

        fun decode(bytes: ByteArray): SupplyExchangePacket? {
            return try {
                if (bytes.size < 11) return null
                val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
                if ((buffer.get().toInt() and 0xFF) != VERSION) return null
                val action = SupplyExchangeAction.fromWire(buffer.get()) ?: return null
                val itemId = buffer.readText(MAX_ITEM_ID_BYTES) ?: return null
                val itemName = buffer.readText(MAX_ITEM_NAME_BYTES) ?: return null
                val quantity = buffer.int.toLong() and 0xFFFF_FFFFL
                if (quantity == 0L) return null
                val unitLength = buffer.get().toInt() and 0xFF
                if (unitLength !in 1..MAX_UNIT_BYTES || buffer.remaining() != unitLength) return null
                val unit = buffer.readUtf8(unitLength) ?: return null
                SupplyExchangePacket(action, itemId, itemName, quantity, unit)
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
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString()
                    .takeIf(String::isNotBlank)
            } catch (_: java.nio.charset.CharacterCodingException) {
                null
            }
        }

        private fun encodeText(value: String, maxBytes: Int, field: String): ByteArray {
            val bytes = value.toByteArray(Charsets.UTF_8)
            require(value.isNotBlank() && bytes.size <= maxBytes) {
                "$field must be non-empty and at most $maxBytes UTF-8 bytes"
            }
            return bytes
        }
    }
}
