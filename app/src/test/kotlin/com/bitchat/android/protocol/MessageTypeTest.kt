package com.bitchat.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 封包類型值不能重複。enum 不會擋重複的 value，[MessageType.fromValue] 又只回傳第一個符合的，
 * 撞號時後面那個類型的封包會被當成前面那個處理，編譯與其他測試都不會發現（SUPPLY_EXCHANGE
 * 曾經和 ADMIN_NOTICE 同為 0x31）。
 */
class MessageTypeTest {

    @Test
    fun `every message type has its own wire value`() {
        val duplicates = MessageType.values()
            .groupBy { it.value }
            .filterValues { it.size > 1 }
        assertEquals(emptyMap<UByte, List<MessageType>>(), duplicates)
    }

    @Test
    fun `fromValue finds every message type by its own value`() {
        for (type in MessageType.values()) {
            assertEquals(type, MessageType.fromValue(type.value))
        }
    }
}
