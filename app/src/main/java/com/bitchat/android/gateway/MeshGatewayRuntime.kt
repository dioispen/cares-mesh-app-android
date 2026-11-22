package com.bitchat.android.gateway

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import com.bitchat.android.mesh.VerifiedHealthReport
import com.bitchat.android.mesh.VerifiedHealthReportBridge
import com.bitchat.android.mesh.VerifiedSupplyExchange
import com.bitchat.android.mesh.VerifiedSupplyExchangeBridge
import com.bitchat.android.sync.PacketIdUtil
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.service.MeshServiceHolder
import com.bitchat.android.service.MeshServicePreferences
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * The Gateway as it runs inside MeshForegroundService (#111): wires [MeshGateway] to the protocol
 * hook ([VerifiedHealthReportBridge]), the sign-in state FirebaseAuth shares with Flutter, the
 * default network, the user's Gateway switch (#113), and Firestore. The service starts it in
 * onCreate and stops it in onDestroy, so the Gateway lives exactly as long as the mesh service, App
 * screens closed or not.
 */
class MeshGatewayRuntime internal constructor(
    private val auth: FirebaseAuth,
    private val connectivity: ConnectivityManager?,
    private val gateway: MeshGateway,
    private val scope: CoroutineScope,
    /** The stored Gateway switch; the Flutter settings screen writes it through SettingsBridge. */
    private val isEnabled: () -> Boolean = { MeshServicePreferences.isGatewayEnabled() },
    /** Follows the switch until the returned function is called. */
    private val observeEnabled: ((Boolean) -> Unit) -> () -> Unit = MeshServicePreferences::observeGatewayEnabled,
    /** The sender's verified, signed ANNOUNCE from the Health Report key cache (ADR-0006). */
    private val announcementFor: (String) -> BitchatPacket? = { peerID ->
        MeshServiceHolder.meshService?.healthReportAnnouncementFor(peerID)
    },
    /** 物資封包的 Gateway，與 Health Report 的共用開關、登入與網路事件；null 時只代傳 Health Report。 */
    private val supplyGateway: MeshSupplyGateway? = null
) {
    private var stopObservingSwitch: (() -> Unit)? = null

    /**
     * Runs on MessageHandler's coroutine: only encode what was received and hand it over. The
     * ANNOUNCE is looked up now, while the key cache still holds it, and travels with the report.
     */
    private val reportListener: (VerifiedHealthReport) -> Unit = { verified ->
        val rawPacket = verified.packet.toBinaryData(padding = false)
        if (rawPacket == null) {
            Log.w(TAG, "Could not re-encode a received Health Report; not uploaded")
        } else {
            val announcement = announcementFor(verified.senderPeerID)?.toBinaryData(padding = false)
            gateway.onReport(GatewayReport(verified.report, verified.senderPeerID.lowercase(), rawPacket, announcement))
        }
    }

    /** 物資封包：只重新編碼收到的封包、算 Packet ID，其餘交給 [MeshSupplyGateway]。 */
    private val supplyListener: (VerifiedSupplyExchange) -> Unit = { verified ->
        val rawPacket = verified.packet.toBinaryData(padding = false)
        if (rawPacket == null) {
            Log.w(TAG, "Could not re-encode a received supply packet; not uploaded")
        } else {
            supplyGateway?.onPacket(
                GatewaySupplyPacket(
                    supply = verified.supply,
                    senderPeerID = verified.senderPeerID.lowercase(),
                    packetId = PacketIdUtil.computeIdHex(verified.packet),
                    rawPacket = rawPacket,
                    createdAtMs = verified.packet.timestamp.toLong()
                )
            )
        }
    }

    /** Called at once with the current user when added, then on every sign-in and sign-out. */
    private val authListener = FirebaseAuth.AuthStateListener { firebaseAuth ->
        gateway.onSignedIn(firebaseAuth.currentUser?.uid)
        supplyGateway?.onSignedIn(firebaseAuth.currentUser?.uid)
    }

    /** "Online" means the default network can reach the internet and Android has validated it. */
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            val online = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            gateway.onNetworkChanged(online)
            supplyGateway?.onNetworkChanged(online)
        }

        override fun onLost(network: Network) {
            gateway.onNetworkChanged(false)
            supplyGateway?.onNetworkChanged(false)
        }
    }

    internal fun start() {
        // The switch first: no report may be uploaded before a switched-off Gateway knows it.
        gateway.onEnabledChanged(isEnabled())
        supplyGateway?.onEnabledChanged(isEnabled())
        stopObservingSwitch = observeEnabled { enabled ->
            gateway.onEnabledChanged(enabled)
            supplyGateway?.onEnabledChanged(enabled)
        }
        auth.addAuthStateListener(authListener)
        try {
            connectivity?.registerDefaultNetworkCallback(networkCallback)
        } catch (e: RuntimeException) {
            // Without network events the Gateway stays offline and uploads nothing.
            Log.w(TAG, "Cannot watch the default network: ${e.message}")
        }
        VerifiedHealthReportBridge.addListener(reportListener)
        if (supplyGateway != null) VerifiedSupplyExchangeBridge.addListener(supplyListener)
    }

    fun stop() {
        VerifiedHealthReportBridge.removeListener(reportListener)
        VerifiedSupplyExchangeBridge.removeListener(supplyListener)
        try {
            connectivity?.unregisterNetworkCallback(networkCallback)
        } catch (e: IllegalArgumentException) {
            // Registration had failed; nothing to unregister.
        }
        auth.removeAuthStateListener(authListener)
        stopObservingSwitch?.invoke()
        stopObservingSwitch = null
        gateway.stop()
        supplyGateway?.stop()
        scope.cancel()
    }

    companion object {
        private const val TAG = "MeshGatewayRuntime"

        /** Null when Firebase is not available in this process; the mesh then runs without a Gateway. */
        fun start(context: Context): MeshGatewayRuntime? {
            val (auth, uploader, supplyUploader) = try {
                Triple(FirebaseAuth.getInstance(), FirestoreMeshReportUploader(), FirestoreMeshSupplyUploader())
            } catch (e: IllegalStateException) {
                Log.w(TAG, "Firebase is not initialised; no Gateway: ${e.message}")
                return null
            }
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val gateway = MeshGateway(uploader, System::currentTimeMillis, scope)
            val supplyGateway = MeshSupplyGateway(supplyUploader, System::currentTimeMillis, scope)
            return MeshGatewayRuntime(
                auth = auth,
                connectivity = context.getSystemService(ConnectivityManager::class.java),
                gateway = gateway,
                scope = scope,
                supplyGateway = supplyGateway
            ).also { it.start() }
        }
    }
}
