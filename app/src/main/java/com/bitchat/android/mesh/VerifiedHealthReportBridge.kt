package com.bitchat.android.mesh

import android.util.Log
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.HealthReportPayload
import java.util.concurrent.CopyOnWriteArraySet

/**
 * A Health Report that passed MessageHandler's checks: its signature verified (a verified peer, or
 * a departed Reporter's cached key, #95), its payload decodes, and its Reporter Handle is not a
 * field-experiment one. Live flood and gossip sync deliver alike.
 */
class VerifiedHealthReport(
    /**
     * The HEALTH_REPORT packet as received: the payload still starts with the BroadcastContentTag,
     * and signature and wire encoding are intact, so the signature can be checked again later.
     */
    val packet: BitchatPacket,
    val report: HealthReportPayload,
    val senderPeerID: String
)

/**
 * Process-wide hook handing verified Health Reports to the Gateway (ADR-0009), the way
 * [InboundPacketBridge] hands packets to Flutter. It lives in `mesh/` so the protocol layer never
 * depends on Firebase: the Gateway registers here, not the other way round.
 *
 * Listeners run on MessageHandler's coroutine and must return quickly.
 */
object VerifiedHealthReportBridge {
    private const val TAG = "VerifiedHealthReportBridge"

    private val listeners = CopyOnWriteArraySet<(VerifiedHealthReport) -> Unit>()

    fun addListener(listener: (VerifiedHealthReport) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (VerifiedHealthReport) -> Unit) {
        listeners.remove(listener)
    }

    /** Called by MessageHandler. A failing listener must not stop the mesh handling the packet. */
    internal fun publish(report: VerifiedHealthReport) {
        listeners.forEach { listener ->
            try {
                listener(report)
            } catch (e: Exception) {
                Log.w(TAG, "Health Report listener failed: ${e.message}")
            }
        }
    }
}
