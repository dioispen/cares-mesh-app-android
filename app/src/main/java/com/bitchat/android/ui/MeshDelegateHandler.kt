package com.bitchat.android.ui

import com.bitchat.android.mesh.BluetoothMeshDelegate
import com.bitchat.android.ui.NotificationTextUtils
import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.DeliveryStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Date

/**
 * Handles all BluetoothMeshDelegate callbacks and routes them to appropriate managers
 */
class MeshDelegateHandler(
    private val state: ChatState,
    private val messageManager: MessageManager,
    private val channelManager: ChannelManager,
    private val privateChatManager: PrivateChatManager,
    private val notificationManager: NotificationManager,
    private val coroutineScope: CoroutineScope,
    private val onHapticFeedback: () -> Unit,
    private val getMyPeerID: () -> String,
    private val getMeshService: () -> BluetoothMeshService
) : BluetoothMeshDelegate {

    override fun didReceiveMessage(message: BitchatMessage) {
        coroutineScope.launch {
            // Deduplicate messages from dual connection paths
            val messageKey = messageManager.generateMessageKey(message)
            if (messageManager.isMessageProcessed(messageKey)) {
                return@launch // Duplicate message, ignore
            }
            messageManager.markMessageProcessed(messageKey)
            
            // Check if sender is blocked
            message.senderPeerID?.let { senderPeerID ->
                if (privateChatManager.isPeerBlocked(senderPeerID)) {
                    return@launch
                }
            }
            
            // Trigger haptic feedback
            onHapticFeedback()

            if (message.isPrivate) {
                // Private message
                privateChatManager.handleIncomingPrivateMessage(message)

                // Reactive read receipts: if chat is focused, send immediately for this message
                message.senderPeerID?.let { senderPeerID ->
                    sendReadReceiptIfFocused(message)
                }
                
                // Show notification with enhanced information
                message.senderPeerID?.let { senderPeerID ->
                    // Use nickname if available, fall back to sender or senderPeerID
                    val senderNickname = message.sender.takeIf { it != senderPeerID } ?: senderPeerID
                    val preview = NotificationTextUtils.buildPrivateMessagePreview(message)
                    notificationManager.showPrivateMessageNotification(
                        senderPeerID = senderPeerID,
                        senderNickname = senderNickname,
                        messageContent = preview
                    )
                }
            } else if (message.channel != null) {
                // Channel message
                if (state.getJoinedChannelsValue().contains(message.channel)) {
                    val channel = message.channel
                    val viewingClassic = state.getCurrentChannelValue() == channel
                    if (!viewingClassic) {
                        val currentUnread = state.getUnreadChannelMessagesValue().toMutableMap()
                        currentUnread[channel] = (currentUnread[channel] ?: 0) + 1
                        state.setUnreadChannelMessages(currentUnread)
                    }
                }
            } else {
                // Public mesh message
                checkAndTriggerMeshMentionNotification(message)
            }
            
            // Periodic cleanup
            if (messageManager.isMessageProcessed("cleanup_check_${System.currentTimeMillis()/30000}")) {
                messageManager.cleanupDeduplicationCaches()
            }
        }
    }
    
    override fun didUpdatePeerList(peers: List<String>) {
        coroutineScope.launch {
            state.setConnectedPeers(peers)
            state.setIsConnected(peers.isNotEmpty())
            notificationManager.showActiveUserNotification(peers)
            
            // Flush router outbox for any peers that just connected
            runCatching { com.bitchat.android.services.MessageRouter.tryGetInstance()?.onPeersUpdated(peers) }

            // Clean up channel members who disconnected
            channelManager.cleanupDisconnectedMembers(peers, getMyPeerID())

            // Handle chat view migration based on current selection and new peer list
            state.getSelectedPrivateChatPeerValue()?.let { currentPeer ->
                val isNoiseHex = currentPeer.length == 64 && currentPeer.matches(Regex("^[0-9a-fA-F]+$"))
                val isMeshEphemeral = currentPeer.length == 16 && currentPeer.matches(Regex("^[0-9a-fA-F]+$"))

                if (isNoiseHex) {
                    val canonical = com.bitchat.android.services.ConversationAliasResolver.resolveCanonicalPeerID(
                        selectedPeerID = currentPeer,
                        connectedPeers = peers,
                        meshNoiseKeyForPeer = { pid -> getPeerInfo(pid)?.noisePublicKey },
                        meshHasPeer = { pid -> peers.contains(pid) },
                        nostrPubHexForAlias = { null },
                        findNoiseKeyForNostr = { null }
                    )
                    if (canonical != currentPeer) {
                        com.bitchat.android.services.ConversationAliasResolver.unifyChatsIntoPeer(state, canonical, listOf(currentPeer))
                        state.setSelectedPrivateChatPeer(canonical)
                    }
                } else if (isMeshEphemeral && !peers.contains(currentPeer)) {
                    val favoriteRel = try {
                        val info = getPeerInfo(currentPeer)
                        val noiseKey = info?.noisePublicKey
                        if (noiseKey != null) {
                            com.bitchat.android.favorites.FavoritesPersistenceService.shared.getFavoriteStatus(noiseKey)
                        } else null
                    } catch (_: Exception) { null }

                    if (favoriteRel?.isMutual == true) {
                        val noiseHex = favoriteRel.peerNoisePublicKey.joinToString("") { b -> "%02x".format(b) }
                        if (noiseHex != currentPeer) {
                            com.bitchat.android.services.ConversationAliasResolver.unifyChatsIntoPeer(
                                state = state,
                                targetPeerID = noiseHex,
                                keysToMerge = listOf(currentPeer)
                            )
                            state.setSelectedPrivateChatPeer(noiseHex)
                        }
                    } else {
                        privateChatManager.cleanupDisconnectedPeer(currentPeer)
                    }
                }
            }

            // Global unification
            peers.forEach { pid ->
                try {
                    val info = getPeerInfo(pid)
                    val noiseKey = info?.noisePublicKey ?: return@forEach
                    val noiseHex = noiseKey.joinToString("") { b -> "%02x".format(b) }
                    unifyChatsIntoPeer(pid, listOf(noiseHex))
                } catch (_: Exception) { }
            }
        }
    }

    private fun unifyChatsIntoPeer(targetPeerID: String, keysToMerge: List<String>) {
        com.bitchat.android.services.ConversationAliasResolver.unifyChatsIntoPeer(state, targetPeerID, keysToMerge)
    }

    override fun didReceiveChannelLeave(channel: String, fromPeer: String) {
        coroutineScope.launch {
            channelManager.removeChannelMember(channel, fromPeer)
        }
    }
    
    override fun didReceiveDeliveryAck(messageID: String, recipientPeerID: String) {
        coroutineScope.launch {
            messageManager.updateMessageDeliveryStatus(messageID, DeliveryStatus.Delivered(recipientPeerID, Date()))
        }
    }
    
    override fun didReceiveReadReceipt(messageID: String, recipientPeerID: String) {
        coroutineScope.launch {
            messageManager.updateMessageDeliveryStatus(messageID, DeliveryStatus.Read(recipientPeerID, Date()))
        }
    }

    override fun didReceiveVerifyChallenge(peerID: String, payload: ByteArray, timestampMs: Long) {
    }

    override fun didReceiveVerifyResponse(peerID: String, payload: ByteArray, timestampMs: Long) {
    }
    
    override fun decryptChannelMessage(encryptedContent: ByteArray, channel: String): String? {
        return channelManager.decryptChannelMessage(encryptedContent, channel)
    }
    
    override fun getNickname(): String? = state.getNicknameValue()
    
    override fun isFavorite(peerID: String): Boolean {
        return privateChatManager.isFavorite(peerID)
    }
    
    private fun checkAndTriggerMeshMentionNotification(message: BitchatMessage) {
        try {
            val currentNickname = state.getNicknameValue()
            if (currentNickname.isNullOrEmpty()) {
                return
            }

            val isMention = checkForMeshMention(message.content, currentNickname)

            if (isMention) {
                notificationManager.showMeshMentionNotification(
                    senderNickname = message.sender,
                    messageContent = message.content,
                    senderPeerID = message.senderPeerID
                )
            }
        } catch (e: Exception) {
            android.util.Log.e("MeshDelegateHandler", "Error checking mesh mentions: ${e.message}")
        }
    }

    private fun checkForMeshMention(content: String, currentNickname: String): Boolean {
        val mentionPattern = "@([\\p{L}0-9_]+)".toRegex()

        return mentionPattern.findAll(content).any { match ->
            val mentionedUsername = match.groupValues[1]
            mentionedUsername.equals(currentNickname, ignoreCase = true)
        }
    }

    private fun sendReadReceiptIfFocused(message: BitchatMessage) {
        val isAppInBackground = notificationManager.getAppBackgroundState()
        val currentPrivateChatPeer = notificationManager.getCurrentPrivateChatPeer()
        
        val senderPeerID = message.senderPeerID
        val shouldSendReadReceipt = !isAppInBackground && senderPeerID != null && currentPrivateChatPeer == senderPeerID
        
            if (shouldSendReadReceipt) {
                val nickname = state.getNicknameValue() ?: "unknown"
                getMeshService().sendReadReceipt(message.id, senderPeerID!!, nickname)
                try {
                    val current = state.getUnreadPrivateMessagesValue().toMutableSet()
                    if (current.remove(senderPeerID)) {
                        state.setUnreadPrivateMessages(current)
                    }
                } catch (_: Exception) { }
            }
        }
    
    fun getPeerInfo(peerID: String): com.bitchat.android.mesh.PeerInfo? {
        return getMeshService().getPeerInfo(peerID)
    }

}
