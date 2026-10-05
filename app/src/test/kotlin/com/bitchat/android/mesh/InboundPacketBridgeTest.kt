package com.bitchat.android.mesh

import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class InboundPacketBridgeTest {

    private val packet = BitchatPacket(
        type = MessageType.HEALTH_REPORT.value,
        ttl = 3u,
        senderID = "0102030405060708",
        payload = byteArrayOf(1, 2, 3)
    )
    private val registered = mutableListOf<(BitchatPacket) -> Unit>()

    @After
    fun tearDown() {
        registered.forEach(InboundPacketBridge::removeListener)
    }

    private fun listen(sink: MutableList<String>, name: String): (BitchatPacket) -> Unit {
        val listener: (BitchatPacket) -> Unit = { sink += name }
        InboundPacketBridge.addListener(listener)
        registered += listener
        return listener
    }

    @Test
    fun `hook is null while no bridge is attached`() {
        assertNull(InboundPacketBridge.onPacketReceived)
    }

    @Test
    fun `attached bridge receives published packets`() {
        val received = mutableListOf<String>()
        listen(received, "bridge")

        InboundPacketBridge.onPacketReceived?.invoke(packet)

        assertEquals(listOf("bridge"), received)
    }

    @Test
    fun `old bridge torn down after the new one attached does not clear the new hook`() {
        val received = mutableListOf<String>()
        val old = listen(received, "old")
        listen(received, "new")

        // Activity recreation: the replacement's configureFlutterEngine can run before the
        // outgoing instance's cleanUpFlutterEngine.
        InboundPacketBridge.removeListener(old)
        InboundPacketBridge.onPacketReceived?.invoke(packet)

        assertEquals(listOf("new"), received)
    }

    @Test
    fun `hook returns to null once every bridge detached`() {
        val received = mutableListOf<String>()
        val first = listen(received, "first")
        val second = listen(received, "second")

        InboundPacketBridge.removeListener(first)
        InboundPacketBridge.removeListener(second)

        assertNull(InboundPacketBridge.onPacketReceived)
    }

    @Test
    fun `removing a listener that was never attached leaves others intact`() {
        val received = mutableListOf<String>()
        listen(received, "bridge")

        InboundPacketBridge.removeListener { }
        InboundPacketBridge.onPacketReceived?.invoke(packet)

        assertEquals(listOf("bridge"), received)
    }
}
