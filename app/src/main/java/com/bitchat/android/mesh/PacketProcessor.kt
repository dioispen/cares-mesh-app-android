package com.bitchat.android.mesh

import android.util.Log
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.model.RoutedPacket
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.actor

/**
 * Processes incoming packets and routes them to appropriate handlers
 * 
 * Per-peer packet serialization using Kotlin coroutine actors
 * Prevents race condition where multiple threads process packets
 * from the same peer simultaneously, causing session management conflicts.
 *
 * [dispatcher] runs the actors. Production keeps [Dispatchers.IO]; a test passes a test dispatcher
 * and runs the actors to idle instead of waiting for them.
 */
class PacketProcessor(
    private val myPeerID: String,
    dispatcher: CoroutineDispatcher = Dispatchers.IO
) {
    private val debugManager by lazy { try { com.bitchat.android.ui.debug.DebugSettingsManager.getInstance() } catch (e: Exception) { null } }
    
    companion object {
        private const val TAG = "PacketProcessor"

        /**
         * The one actor every Admin Notice packet, and every fragment of one, is serialised on.
         * Their senderID is a messageId, not a peer: an actor per senderID would only be cleaned up
         * when that "peer" leaves, which it never does (ADR-0011). Not hex, so it never collides
         * with a peerID.
         */
        private const val ADMIN_NOTICE_ACTOR = "admin-notice"
    }
    
    // Delegate for callbacks
    var delegate: PacketProcessorDelegate? = null
    
    // Helper function to format peer ID with nickname for logging
    private fun formatPeerForLog(peerID: String): String {
        val nickname = delegate?.getPeerNickname(peerID)
        return if (nickname != null) "$peerID ($nickname)" else peerID
    }
    
    // Packet relay manager for centralized relay decisions
    private val packetRelayManager = PacketRelayManager(myPeerID)
    
    // Coroutines
    private val processorScope = CoroutineScope(dispatcher + SupervisorJob())
    
    // Per-peer actors to serialize packet processing
    // Each peer gets its own actor that processes packets sequentially
    // This prevents race conditions in session management
    private val peerActors = mutableMapOf<String, CompletableDeferred<Unit>>()
    
    @OptIn(ObsoleteCoroutinesApi::class)
    private fun getOrCreateActorForPeer(peerID: String) = processorScope.actor<RoutedPacket>(
        capacity = Channel.UNLIMITED
    ) {
        for (packet in channel) {
            handleReceivedPacket(packet)
        }
    }
    
    // Cache actors to reuse them
    private val actors = mutableMapOf<String, kotlinx.coroutines.channels.SendChannel<RoutedPacket>>()
    
    init {
        // Set up the packet relay manager delegate immediately
        setupRelayManager()
    }
    
    /**
     * Process received packet - main entry point for all incoming packets
     * SURGICAL FIX: Route to per-peer actor for serialized processing
     */
    fun processPacket(routed: RoutedPacket) {
        val peerID = routed.peerID

        if (peerID == null) {
            Log.w(TAG, "Received packet with no peer ID, skipping")
            return
        }
        
        // Get or create actor for this peer
        val actorKey = if (AdminNoticeTraffic.carriesAdminNotice(routed.packet)) ADMIN_NOTICE_ACTOR else peerID
        val actor = actors.getOrPut(actorKey) { getOrCreateActorForPeer(actorKey) }
        
        // Send packet to peer's dedicated actor for serialized processing
        processorScope.launch {
            try {
                actor.send(routed)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send packet to actor for ${formatPeerForLog(peerID)}: ${e.message}")
                // Fallback to direct processing if actor fails
                handleReceivedPacket(routed)
            }
        }
    }
    
    /**
     * Release the actor for a peer that has disconnected.
     * Prevents unbounded growth of the actors map when peers come and go.
     */
    fun cleanupPeer(peerID: String) {
        actors.remove(peerID)?.let { channel ->
            try { channel.close() } catch (_: Exception) { }
            Log.d(TAG, "🎭 Cleaned up packet actor for departed peer $peerID")
        }
    }

    /** Packet actors alive now: one per peer that sent something, plus at most one for Admin Notices. */
    internal fun activeActorCount(): Int = actors.size

    /**
     * Set up the packet relay manager with its delegate
     */
    fun setupRelayManager() {
        packetRelayManager.delegate = object : PacketRelayManagerDelegate {
            override fun getNetworkSize(): Int {
                return delegate?.getNetworkSize() ?: 1
            }
            
            override fun getBroadcastRecipient(): ByteArray {
                return delegate?.getBroadcastRecipient() ?: ByteArray(0)
            }
            
            override fun broadcastPacket(routed: RoutedPacket) {
                delegate?.relayPacket(routed)
            }
            override fun sendToPeer(peerID: String, routed: RoutedPacket): Boolean {
                return delegate?.sendToPeer(peerID, routed) ?: false
            }
        }
    }
    
    /**
     * Handle received packet - core protocol logic (exact same as iOS)
     */
    private suspend fun handleReceivedPacket(routed: RoutedPacket) {
        val packet = routed.packet
        val peerID = routed.peerID ?: "unknown"

        // Basic validation and security checks
        if (!delegate?.validatePacketSecurity(routed)!!) {
            return
        }

        var validPacket = true
        val messageType = MessageType.fromValue(packet.type)
        // An Admin Notice's senderID is its messageId: nobody to log, or mark as seen, as its sender.
        val senderIsPeer = !AdminNoticeTraffic.carriesAdminNotice(packet)
        // Verbose logging to debug manager (and chat via ChatViewModel observer)
        if (senderIsPeer) try {
            val mt = messageType?.name ?: packet.type.toString()
            val routeDevice = routed.relayAddress
            val nick = delegate?.getPeerNickname(peerID)
            debugManager?.logIncomingPacket(peerID, nick, mt, routeDevice)
        } catch (_: Exception) { }
        
        
        // Handle public packet types (no address check needed)
        when (messageType) {
            MessageType.ANNOUNCE -> validPacket = handleAnnounce(routed)
            MessageType.MESSAGE -> handleMessage(routed)
            MessageType.FILE_TRANSFER -> handleMessage(routed) // treat same routing path; parsing happens in handler
            MessageType.VOICE_FRAME -> validPacket = delegate?.handleVoiceFrame(routed) ?: false
            MessageType.LEAVE -> handleLeave(routed)
            MessageType.FRAGMENT -> validPacket = handleFragment(routed)
            MessageType.REQUEST_SYNC -> handleRequestSync(routed)
            MessageType.HEALTH_REPORT -> handleMessage(routed)
            MessageType.SUPPLY_EXCHANGE -> handleMessage(routed)
            // Relayed only when the Inbox verified the Administrators' signature (ADR-0011).
            MessageType.ADMIN_NOTICE -> validPacket = delegate?.handleAdminNotice(routed) ?: false
            else -> {
                // Handle private packet types (address check required)
                if (packetRelayManager.isPacketAddressedToMe(packet)) {
                    when (messageType) {
                        MessageType.NOISE_HANDSHAKE -> validPacket = handleNoiseHandshake(routed)
                        MessageType.NOISE_ENCRYPTED -> validPacket = handleNoiseEncrypted(routed)
                        MessageType.FILE_TRANSFER -> handleMessage(routed)
                        else -> {
                            validPacket = false
                            Log.w(TAG, "Unknown message type: ${packet.type}")
                        }
                    }
                } else {
                    // Not addressed to us; only relay handling below applies
                }
            }
        }
        
        // Update last seen timestamp
        if (validPacket) {
            if (senderIsPeer) delegate?.updatePeerLastSeen(peerID)
            
            // CENTRALIZED RELAY LOGIC: Handle relay decisions for all packets not addressed to us
            packetRelayManager.handlePacketRelay(
                if (messageType == MessageType.ADMIN_NOTICE) {
                    routed.copy(packet = AdminNoticeTraffic.normalizedForRelay(packet))
                } else {
                    routed
                }
            )
        }
    }
    
    /**
     * Handle Noise handshake message - SIMPLIFIED iOS-compatible version
     */
    private suspend fun handleNoiseHandshake(routed: RoutedPacket): Boolean {
        return delegate?.handleNoiseHandshake(routed) ?: false
    }
    
    /**
     * Handle Noise encrypted transport message
     * Returns false when decryption fails so undecryptable packets do not prove liveness.
     */
    private suspend fun handleNoiseEncrypted(routed: RoutedPacket): Boolean {
        return delegate?.handleNoiseEncrypted(routed) ?: false
    }
    
    /**
     * Handle announce message
     */
    private suspend fun handleAnnounce(routed: RoutedPacket): Boolean {
        return delegate?.handleAnnounce(routed) ?: false
    }
    
    /**
     * Handle regular message
     */
    private suspend fun handleMessage(routed: RoutedPacket) {
        delegate?.handleMessage(routed)
    }
    
    /**
     * Handle leave message
     */
    private suspend fun handleLeave(routed: RoutedPacket) {
        delegate?.handleLeave(routed)
    }
    
    /**
     * Handle message fragments. Returns whether the fragment itself is relayed (validPacket): an
     * Admin Notice's fragment is not, see [AdminNoticeTraffic.relaysFragment].
     */
    private suspend fun handleFragment(routed: RoutedPacket): Boolean {
        val reassembledPacket = delegate?.handleFragment(routed.packet)
        if (reassembledPacket != null) {
            handleReceivedPacket(
                RoutedPacket(
                    packet = AdminNoticeTraffic.reassembled(reassembledPacket, completedBy = routed.packet),
                    peerID = routed.peerID,
                    relayAddress = routed.relayAddress,
                    ingressLinkID = routed.ingressLinkID
                )
            )
        }

        // Fragment relay is now handled by centralized PacketRelayManager
        return AdminNoticeTraffic.relaysFragment(routed.packet)
    }

    /**
     * Handle REQUEST_SYNC packets (public, TTL=1)
     */
    private suspend fun handleRequestSync(routed: RoutedPacket) {
        delegate?.handleRequestSync(routed)
    }

    /**
     * Handle delivery acknowledgment
     */
//    private suspend fun handleDeliveryAck(routed: RoutedPacket) {
//        val peerID = routed.peerID ?: "unknown"
//        Log.d(TAG, "Processing delivery ACK from ${formatPeerForLog(peerID)}")
//        delegate?.handleDeliveryAck(routed)
//    }
    
    /**
     * Get debug information
     */
    fun getDebugInfo(): String {
        return buildString {
            appendLine("=== Packet Processor Debug Info ===")
            appendLine("Processor Scope Active: ${processorScope.isActive}")
            appendLine("Active Peer Actors: ${actors.size}")
            appendLine("My Peer ID: $myPeerID")
            
            if (actors.isNotEmpty()) {
                appendLine("Peer Actors:")
                actors.keys.forEach { peerID ->
                    appendLine("  - $peerID")
                }
            }
        }
    }
    
    /**
     * Shutdown the processor and all peer actors
     */
    fun shutdown() {
        Log.d(TAG, "Shutting down PacketProcessor and ${actors.size} peer actors")
        
        // Close all peer actors gracefully
        actors.values.forEach { actor ->
            actor.close()
        }
        actors.clear()
        
        // Shutdown the relay manager
        packetRelayManager.shutdown()
        
        // Cancel the main scope
        processorScope.cancel()
    }
}

/**
 * Delegate interface for packet processor callbacks
 */
interface PacketProcessorDelegate {
    // Security validation; [routed] also carries the link it arrived on (experiment recorder, #70)
    fun validatePacketSecurity(routed: RoutedPacket): Boolean
    
    // Peer management
    fun updatePeerLastSeen(peerID: String)
    fun getPeerNickname(peerID: String): String?
    
    // Network information
    fun getNetworkSize(): Int
    fun getBroadcastRecipient(): ByteArray
    
    // Message type handlers
    fun handleNoiseHandshake(routed: RoutedPacket): Boolean
    fun handleNoiseEncrypted(routed: RoutedPacket): Boolean
    suspend fun handleAnnounce(routed: RoutedPacket): Boolean
    fun handleMessage(routed: RoutedPacket)
    fun handleVoiceFrame(routed: RoutedPacket): Boolean = false
    /** ADMIN_NOTICE (0x31): true when the Inbox accepted it and it should be relayed (validPacket). */
    fun handleAdminNotice(routed: RoutedPacket): Boolean = false
    fun handleLeave(routed: RoutedPacket)
    fun handleFragment(packet: BitchatPacket): BitchatPacket?
    fun handleRequestSync(routed: RoutedPacket)

    // Communication
    fun sendAnnouncementToPeer(peerID: String)
    fun sendCachedMessages(peerID: String)
    fun relayPacket(routed: RoutedPacket)
    fun sendToPeer(peerID: String, routed: RoutedPacket): Boolean
}
