package com.bitchat.android.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * SUPPLY_EXCHANGE（0x32）payload 的編解碼測試。
 *
 * 跨端權威向量 —— Dart 端 `supply_exchange_packet_test.dart` 使用相同的 bytes 與欄位值：
 * version=1, action=request(1), exchangeId=0123456789abcdef0123456789abcdef, itemId="water",
 * itemName="礦泉水", quantity=12, unit="瓶"。
 */
class SupplyExchangePacketTest {

    private val vectorHex = "01010123456789abcdef0123456789abcdef000577617465720009e7a4a6e6b389e6b0b40000000c03e793b6"
    private val vectorBytes: ByteArray = hex(vectorHex)
    private val vector = SupplyExchangePacket(
        action = SupplyExchangeAction.REQUEST,
        exchangeId = "0123456789abcdef0123456789abcdef",
        itemId = "water",
        itemName = "礦泉水",
        quantity = 12,
        unit = "瓶"
    )

    @Test
    fun `packet type is 0x32 because 0x31 is reserved for Admin Notice`() {
        // ADR-0011 把 0x31 給了 ADMIN_NOTICE；Dart 端 BlePacketType.supplyExchange 必須同值。
        assertEquals(0x32u.toUByte(), MessageType.SUPPLY_EXCHANGE.value)
    }

    @Test
    fun `encodes the authoritative vector byte for byte`() {
        assertArrayEquals(vectorBytes, vector.encode())
        assertEquals(44, vectorBytes.size)
    }

    @Test
    fun `decodes the authoritative vector`() {
        assertEquals(vector, SupplyExchangePacket.decode(vectorBytes))
    }

    @Test
    fun `offer round-trips with the largest quantity`() {
        val offer = vector.copy(action = SupplyExchangeAction.OFFER, quantity = 0xFFFF_FFFFL, unit = "組")
        assertEquals(offer, SupplyExchangePacket.decode(offer.encode()))
    }

    @Test
    fun `the map from the bridge builds the same packet`() {
        val fromMap = SupplyExchangePacket.fromMap(
            mapOf(
                "action" to "request",
                "exchangeId" to "0123456789ABCDEF0123456789ABCDEF",
                "itemId" to "water",
                "itemName" to "礦泉水",
                "quantity" to 12,
                "unit" to "瓶"
            )
        )
        assertEquals(vector, fromMap)
        assertNull(SupplyExchangePacket.fromMap(mapOf("action" to "request")))
        assertNull(SupplyExchangePacket.fromMap(mapOf("action" to "cancel", "exchangeId" to vector.exchangeId,
            "itemId" to "water", "itemName" to "礦泉水", "quantity" to 1, "unit" to "瓶")))
        assertNull(SupplyExchangePacket.fromMap(mapOf("action" to "request", "exchangeId" to "abc",
            "itemId" to "water", "itemName" to "礦泉水", "quantity" to 1, "unit" to "瓶")))
    }

    @Test
    fun `rejects unknown version, unknown action, zero quantity, trailing bytes and truncation`() {
        assertNull(SupplyExchangePacket.decode(vectorBytes.copyOf().also { it[0] = 2 }))
        assertNull(SupplyExchangePacket.decode(vectorBytes.copyOf().also { it[1] = 3 }))
        assertNull(SupplyExchangePacket.decode(vectorBytes.copyOf().also { it[37] = 0; it[38] = 0; it[39] = 0 }))
        assertNull(SupplyExchangePacket.decode(vectorBytes + byteArrayOf(0x00)))
        assertNull(SupplyExchangePacket.decode(vectorBytes.copyOfRange(0, vectorBytes.size - 1)))
        assertNull(SupplyExchangePacket.decode(ByteArray(0)))
    }

    @Test
    fun `rejects malformed UTF-8 and blank strings`() {
        val badUtf8 = vectorBytes.copyOf().also { it[20] = 0xFF.toByte() }
        assertNull(SupplyExchangePacket.decode(badUtf8))
        val blankItemId = vectorBytes.copyOf().also { for (i in 20 until 25) it[i] = ' '.code.toByte() }
        assertNull(SupplyExchangePacket.decode(blankItemId))
    }

    @Test
    fun `encoding refuses out-of-range fields`() {
        assertThrows(IllegalArgumentException::class.java) { vector.copy(quantity = 0).encode() }
        assertThrows(IllegalArgumentException::class.java) { vector.copy(quantity = 0x1_0000_0000L).encode() }
        assertThrows(IllegalArgumentException::class.java) { vector.copy(itemId = "").encode() }
        assertThrows(IllegalArgumentException::class.java) {
            vector.copy(itemName = "x".repeat(SupplyExchangePacket.MAX_ITEM_NAME_BYTES + 1)).encode()
        }
        assertThrows(IllegalArgumentException::class.java) { vector.copy(exchangeId = "zz").encode() }
    }

    @Test
    fun `the largest legal packet fits MAX_ENCODED_SIZE`() {
        val largest = vector.copy(
            itemId = "i".repeat(SupplyExchangePacket.MAX_ITEM_ID_BYTES),
            itemName = "n".repeat(SupplyExchangePacket.MAX_ITEM_NAME_BYTES),
            unit = "u".repeat(SupplyExchangePacket.MAX_UNIT_BYTES)
        )
        assertEquals(SupplyExchangePacket.MAX_ENCODED_SIZE, largest.encode().size)
        assertEquals(largest, SupplyExchangePacket.decode(largest.encode()))
    }

    private fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
