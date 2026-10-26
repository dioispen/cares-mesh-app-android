package com.bitchat.android.gateway

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import com.bitchat.android.mesh.VerifiedHealthReport
import com.bitchat.android.mesh.VerifiedHealthReportBridge
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
    private val observeEnabled: ((Boolean) -> Unit) -> () -> Unit = MeshServicePreferences::observeGatewayEnabled
) {
    private var stopObservingSwitch: (() -> Unit)? = null

    /** Runs on MessageHandler's coroutine: only encode what was received and hand it over. */
    private val reportListener: (VerifiedHealthReport) -> Unit = { verified ->
        val rawPacket = verified.packet.toBinaryData(padding = false)
        if (rawPacket == null) {
            Log.w(TAG, "Could not re-encode a received Health Report; not relayed")
        } else {
            val announcement = MeshServiceHolder.meshService
                ?.healthReportAnnouncementFor(verified.senderPeerID)
                ?.toBinaryData(padding = false)
            gateway.onReport(GatewayReport(verified.report, verified.senderPeerID.lowercase(), rawPacket, announcement))
        }
    }

    /** Called at once with the current user when added, then on every sign-in and sign-out. */
    private val authListener = FirebaseAuth.AuthStateListener { firebaseAuth ->
        gateway.onSignedIn(firebaseAuth.currentUser?.uid)
    }

    /** "Online" means the default network can reach the internet and Android has validated it. */
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            gateway.onNetworkChanged(
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            )
        }

        override fun onLost(network: Network) {
            gateway.onNetworkChanged(false)
        }
    }

    internal fun start() {
        // The switch first: no report may be relayed before a switched-off Gateway knows it.
        gateway.onEnabledChanged(isEnabled())
        stopObservingSwitch = observeEnabled(gateway::onEnabledChanged)
        auth.addAuthStateListener(authListener)
        try {
            connectivity?.registerDefaultNetworkCallback(networkCallback)
        } catch (e: RuntimeException) {
            // Without network events the Gateway stays offline and uploads nothing.
            Log.w(TAG, "Cannot watch the default network: ${e.message}")
        }
        VerifiedHealthReportBridge.addListener(reportListener)
    }

    fun stop() {
        VerifiedHealthReportBridge.removeListener(reportListener)
        try {
            connectivity?.unregisterNetworkCallback(networkCallback)
        } catch (e: IllegalArgumentException) {
            // Registration had failed; nothing to unregister.
        }
        auth.removeAuthStateListener(authListener)
        stopObservingSwitch?.invoke()
        stopObservingSwitch = null
        gateway.stop()
        scope.cancel()
    }

    companion object {
        private const val TAG = "MeshGatewayRuntime"

        /** Null when Firebase is not available in this process; the mesh then runs without a Gateway. */
        fun start(context: Context): MeshGatewayRuntime? {
            val (auth, uploader) = try {
                FirebaseAuth.getInstance() to FirestoreMeshReportUploader()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "Firebase is not initialised; no Gateway: ${e.message}")
                return null
            }
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val gateway = MeshGateway(uploader, System::currentTimeMillis, scope)
            return MeshGatewayRuntime(
                auth = auth,
                connectivity = context.getSystemService(ConnectivityManager::class.java),
                gateway = gateway,
                scope = scope
            ).also { it.start() }
        }
    }
}
