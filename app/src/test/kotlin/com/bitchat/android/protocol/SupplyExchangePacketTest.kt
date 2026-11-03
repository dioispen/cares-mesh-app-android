package com.bitchat.android.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SupplyExchangePacketTest {
    private val authoritativeBytes = byteArrayOf(
        1, 1, 0, 5,
        'w'.code.toByte(), 'a'.code.toByte(), 't'.code.toByte(), 'e'.code.toByte(), 'r'.code.toByte(),
        0, 9,
        0xE7.toByte(), 0xA4.toByte(), 0xA6.toByte(), 0xE6.toByte(), 0xB3.toByte(), 0x89.toByte(), 0xE6.toByte(), 0xB0.toByte(), 0xB4.toByte(),
        0, 0, 0, 3,
        3, 0xE7.toByte(), 0x93.toByte(), 0xB6.toByte()
    )

    @Test
    fun `request encodes to the cross-platform vector`() {
        val packet = SupplyExchangePacket(
            SupplyExchangeAction.REQUEST,
            itemId = "water",
            itemName = "礦泉水",
            quantity = 3,
            unit = "瓶"
        )

        assertArrayEquals(authoritativeBytes, packet.encode())
        assertEquals(packet, SupplyExchangePacket.decode(authoritativeBytes))
    }

    @Test
    fun `offer has a distinct action byte`() {
        val bytes = SupplyExchangePacket(
            SupplyExchangeAction.OFFER,
            "blanket",
            "毛毯",
            2,
            "條"
        ).encode()

        assertEquals(SupplyExchangeAction.OFFER, SupplyExchangePacket.decode(bytes)?.action)
        assertEquals(2, bytes[1].toInt())
    }

    @Test
    fun `decoder rejects unknown versions actions zero quantities and trailing bytes`() {
        assertNull(SupplyExchangePacket.decode(authoritativeBytes.copyOf().also { it[0] = 2 }))
        assertNull(SupplyExchangePacket.decode(authoritativeBytes.copyOf().also { it[1] = 3 }))
        assertNull(SupplyExchangePacket.decode(authoritativeBytes.copyOf().also { it[23] = 0 }))
        assertNull(SupplyExchangePacket.decode(authoritativeBytes + byteArrayOf(0)))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `encoder rejects blank item identifiers`() {
        SupplyExchangePacket(SupplyExchangeAction.REQUEST, " ", "Water", 1, "bottle").encode()
    }

    @Test(expected = IllegalArgumentException::class)
    fun `encoder rejects zero quantity`() {
        SupplyExchangePacket(SupplyExchangeAction.OFFER, "water", "Water", 0, "bottle").encode()
    }
}
