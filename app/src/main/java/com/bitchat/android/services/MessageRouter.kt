package com.bitchat.android.services

import android.content.Context
import android.util.Log
import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.model.ReadReceipt

/**
 * Routes messages primarily via BLE mesh transport.
 * Nostr transport integration has been removed.
 */
class MessageRouter private constructor(
    private val context: Context,
    private var mesh: BluetoothMeshService
) {
    companion object {
        private const val TAG = "MessageRouter"
        @Volatile private var INSTANCE: MessageRouter? = null
        fun tryGetInstance(): MessageRouter? = INSTANCE
        fun getInstance(context: Context, mesh: BluetoothMeshService): MessageRouter {
            val instance = INSTANCE ?: synchronized(this) {
                INSTANCE ?: run {
                    MessageRouter(context.applicationContext, mesh).also { instance ->
                        // Register for favorites changes to flush outbox
                        try {
                            com.bitchat.android.favorites.FavoritesPersistenceService.shared.addListener(instance.favoriteListener)
                        } catch (_: Exception) {}
                        INSTANCE = instance
                    }
                }
            }
            // Always update mesh reference
            instance.mesh = mesh
            return instance
        }
    }

    // Outbox: peerID -> queued (content, nickname, messageID)
    private val outbox = mutableMapOf<String, MutableList<Triple<String, String, String>>>()

    // Listener for favorites changes to flush outbox
    private val favoriteListener = object: com.bitchat.android.favorites.FavoritesChangeListener {
        override fun onFavoriteChanged(noiseKeyHex: String) {
            flushOutboxFor(noiseKeyHex)
            val shortId = noiseKeyHex.take(16)
            flushOutboxFor(shortId)
        }
        override fun onAllCleared() {}
    }

    fun sendPrivate(content: String, toPeerID: String, recipientNickname: String, messageID: String) {
        val hasMesh = mesh.getPeerInfo(toPeerID)?.isConnected == true
        val hasEstablished = mesh.hasEstablishedSession(toPeerID)
        if (hasMesh && hasEstablished) {
            Log.d(TAG, "Routing PM via mesh to ${toPeerID} msg_id=${messageID.take(8)}…")
            mesh.sendPrivateMessage(content, toPeerID, recipientNickname, messageID)
        } else {
            Log.d(TAG, "Queued PM for ${toPeerID} (no mesh or no established session) msg_id=${messageID.take(8)}…")
            val q = outbox.getOrPut(toPeerID) { mutableListOf() }
            q.add(Triple(content, recipientNickname, messageID))
            Log.d(TAG, "Initiating noise handshake after queueing PM for ${toPeerID.take(8)}…")
            mesh.initiateNoiseHandshake(toPeerID)
        }
    }

    fun sendReadReceipt(receipt: ReadReceipt, toPeerID: String) {
        if ((mesh.getPeerInfo(toPeerID)?.isConnected == true) && mesh.hasEstablishedSession(toPeerID)) {
            Log.d(TAG, "Routing READ via mesh to ${toPeerID.take(8)}… id=${receipt.originalMessageID.take(8)}…")
            mesh.sendReadReceipt(receipt.originalMessageID, toPeerID, mesh.getPeerNicknames()[toPeerID] ?: mesh.myPeerID)
        }
    }

    fun sendDeliveryAck(messageID: String, toPeerID: String) {
        // Mesh delivery ACKs are sent by the receiver automatically via BLE layer.
    }

    fun sendFavoriteNotification(toPeerID: String, isFavorite: Boolean) {
        if (mesh.getPeerInfo(toPeerID)?.isConnected == true) {
            val content = if (isFavorite) "[FAVORITED]" else "[UNFAVORITED]"
            val nickname = mesh.getPeerNicknames()[toPeerID] ?: toPeerID
            mesh.sendPrivateMessage(content, toPeerID, nickname)
        }
    }

    fun flushOutboxFor(peerID: String) {
        val queued = outbox[peerID] ?: return
        if (queued.isEmpty()) return
        Log.d(TAG, "Flushing outbox for ${peerID.take(8)}… count=${queued.size}")
        val iterator = queued.iterator()
        while (iterator.hasNext()) {
            val (content, nickname, messageID) = iterator.next()
            var hasMesh = mesh.getPeerInfo(peerID)?.isConnected == true && mesh.hasEstablishedSession(peerID)
            
            if (!hasMesh && peerID.length == 64 && peerID.matches(Regex("^[0-9a-fA-F]+$"))) {
                val meshPeer = resolveMeshPeerForNoiseHex(peerID)
                if (meshPeer != null && mesh.getPeerInfo(meshPeer)?.isConnected == true && mesh.hasEstablishedSession(meshPeer)) {
                    mesh.sendPrivateMessage(content, meshPeer, nickname, messageID)
                    iterator.remove()
                    continue
                }
            }
            if (hasMesh) {
                mesh.sendPrivateMessage(content, peerID, nickname, messageID)
                iterator.remove()
            }
        }
        if (queued.isEmpty()) {
            outbox.remove(peerID)
        }
    }

    fun flushAllOutbox() {
        outbox.keys.toList().forEach { flushOutboxFor(it) }
    }

    private fun resolveMeshPeerForNoiseHex(noiseHex: String): String? {
        return try {
            mesh.getPeerNicknames().keys.firstOrNull { pid ->
                val info = mesh.getPeerInfo(pid)
                val keyHex = info?.noisePublicKey?.joinToString("") { b -> "%02x".format(b) }
                keyHex != null && keyHex.equals(noiseHex, ignoreCase = true)
            }
        } catch (_: Exception) { null }
    }

    fun onPeersUpdated(peers: List<String>) {
        peers.forEach { pid ->
            flushOutboxFor(pid)
            val noiseHex = try {
                mesh.getPeerInfo(pid)?.noisePublicKey?.joinToString("") { b -> "%02x".format(b) }
            } catch (_: Exception) { null }
            noiseHex?.let { flushOutboxFor(it) }
        }
    }

    fun onSessionEstablished(peerID: String) {
        flushOutboxFor(peerID)
        val noiseHex = try {
            mesh.getPeerInfo(peerID)?.noisePublicKey?.joinToString("") { b -> "%02x".format(b) }
        } catch (_: Exception) { null }
        noiseHex?.let { flushOutboxFor(it) }
    }
}
