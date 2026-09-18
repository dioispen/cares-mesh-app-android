package com.bitchat.android.mesh

import com.bitchat.android.protocol.BitchatPacket

/**
 * Process-wide hook for handing inbound mesh packets to a UI layer (the Flutter bridge).
 *
 * Deliberately lives in `mesh/` rather than on `service.MeshServiceHolder`: the shared protocol
 * stack is compiled into the :wear module too, and that module excludes the phone's service
 * layer. Keeping the hook here lets MessageHandler publish packets without dragging
 * BluetoothMeshService/UnifiedMeshService into the watch build.
 */
object InboundPacketBridge {
    /** Set by BitchatFlutterChannels while the Flutter UI is attached; null otherwise. */
    @Volatile
    var onPacketReceived: ((BitchatPacket) -> Unit)? = null
}
