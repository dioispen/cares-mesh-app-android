package com.bitchat.android.mesh

import com.bitchat.android.protocol.BitchatPacket
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Process-wide hook for handing inbound mesh packets to a UI layer (the Flutter bridge).
 *
 * Deliberately lives in `mesh/` rather than on `service.MeshServiceHolder`: the shared protocol
 * stack is compiled into the :wear module too, and that module excludes the phone's service
 * layer. Keeping the hook here lets MessageHandler publish packets without dragging
 * BluetoothMeshService/UnifiedMeshService into the watch build.
 *
 * Each attached bridge registers its own listener rather than overwriting a single slot. When
 * the Flutter Activity is recreated, the replacement can attach before the outgoing instance is
 * torn down; removing the outgoing listener must not clear the replacement's.
 */
object InboundPacketBridge {
    private val listeners = CopyOnWriteArraySet<(BitchatPacket) -> Unit>()
    private val fanOut: (BitchatPacket) -> Unit = { packet -> listeners.forEach { it(packet) } }

    /** Read by MessageHandler to publish a packet; null while no bridge is attached. */
    val onPacketReceived: ((BitchatPacket) -> Unit)?
        get() = if (listeners.isEmpty()) null else fanOut

    /** Called by BitchatFlutterChannels while its Flutter engine is attached. */
    fun addListener(listener: (BitchatPacket) -> Unit) {
        listeners.add(listener)
    }

    /** Removes only [listener]; other attached bridges keep receiving packets. */
    fun removeListener(listener: (BitchatPacket) -> Unit) {
        listeners.remove(listener)
    }
}
