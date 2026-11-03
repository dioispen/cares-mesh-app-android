package com.bitchat.android.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.ConnectivityManager.NetworkCallback
import android.util.AtomicFile
import android.util.Base64
import android.util.Log
import com.bitchat.android.mesh.InboundPacketBridge
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SupplyExchangePacket
import com.bitchat.android.sync.PacketIdUtil
import com.bitchat.android.util.toHexString
import com.google.android.gms.tasks.Tasks
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.Date

/**
 * Persists validated inbound supply packets and uploads them while a signed-in user
 * has validated internet. The durable outbox survives service and process restarts.
 */
internal class MeshSupplyGateway(
    context: Context,
    private val scope: CoroutineScope
) : AutoCloseable {
    private val appContext = context.applicationContext
    private val outbox = SupplyPacketOutbox(File(appContext.filesDir, OUTBOX_FILE))
    private val auth = FirebaseAuth.getInstance()
    private val firestore = FirebaseFirestore.getInstance()
    private val connectivity = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val flushMutex = Mutex()
    @Volatile
    private var closed = false

    private val packetListener: (BitchatPacket) -> Unit = { packet ->
        if (packet.type == MessageType.SUPPLY_EXCHANGE.value) {
            scope.launch(Dispatchers.IO) { enqueue(packet) }
        }
    }

    private val authListener = FirebaseAuth.AuthStateListener { requestFlush() }
    private val networkCallback = object : NetworkCallback() {
        override fun onAvailable(network: Network) {
            requestFlush()
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (isValidatedInternet(capabilities)) requestFlush()
        }
    }

    init {
        InboundPacketBridge.addListener(packetListener)
        auth.addAuthStateListener(authListener)
        try {
            connectivity.registerDefaultNetworkCallback(networkCallback)
        } catch (e: RuntimeException) {
            Log.e(TAG, "Could not monitor network changes; queued supply packets remain on disk", e)
        }
        requestFlush()
    }

    private fun enqueue(packet: BitchatPacket) {
        if (closed || packet.signature == null || SupplyExchangePacket.decode(packet.payload) == null) return
        val packetId = PacketIdUtil.computeIdHex(packet)
        val rawPacket = packet.toBinaryData(padding = false)
        if (rawPacket == null) {
            Log.e(TAG, "Could not encode received supply packet for durable upload")
            return
        }
        try {
            val added = outbox.enqueue(packetId, rawPacket)
            if (added) Log.i(TAG, "Queued inbound supply packet ${packetId.take(8)}")
        } catch (e: IOException) {
            Log.e(TAG, "Could not persist inbound supply packet ${packetId.take(8)}", e)
            return
        } catch (e: IllegalStateException) {
            Log.e(TAG, "Supply outbox is full; packet ${packetId.take(8)} was not queued", e)
            return
        }
        requestFlush()
    }

    private fun requestFlush() {
        if (closed || auth.currentUser == null || !hasValidatedInternet()) return
        scope.launch(Dispatchers.IO) {
            if (!flushMutex.tryLock()) return@launch
            var completedWithoutError = true
            try {
                while (!closed && auth.currentUser != null && hasValidatedInternet()) {
                    val entry = outbox.firstOrNull() ?: break
                    try {
                        upload(entry, auth.currentUser?.uid ?: break)
                        outbox.remove(entry.packetId)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        completedWithoutError = false
                        Log.e(TAG, "Supply packet upload failed; keeping it in the durable outbox", e)
                        break
                    }
                }
            } finally {
                flushMutex.unlock()
                if (completedWithoutError && outbox.hasPending()) requestFlush()
            }
        }
    }

    private fun upload(entry: PendingSupplyPacket, gatewayUid: String) {
        val packet = BitchatPacket.fromBinaryData(entry.rawPacket)
            ?: throw IOException("Queued supply packet could not be decoded")
        val payload = SupplyExchangePacket.decode(packet.payload)
            ?: throw IOException("Queued supply payload is invalid")
        val encodedPacketId = PacketIdUtil.computeIdHex(packet)
        if (packet.type != MessageType.SUPPLY_EXCHANGE.value ||
            packet.signature == null ||
            encodedPacketId != entry.packetId
        ) {
            throw IOException("Queued supply packet failed integrity checks")
        }

        val document = firestore.collection(COLLECTION).document(entry.packetId)
        val fields = mapOf(
            "schemaVersion" to SCHEMA_VERSION,
            "packetId" to entry.packetId,
            "packetType" to packet.type.toInt(),
            "payloadVersion" to SupplyExchangePacket.VERSION,
            "action" to payload.action.value,
            "originPeerId" to packet.senderID.toHexString(),
            "itemId" to payload.itemId,
            "itemName" to payload.itemName,
            "quantity" to payload.quantity,
            "unit" to payload.unit,
            "createdAt" to Timestamp(Date(packet.timestamp.toLong())),
            "rawPacket" to Base64.encodeToString(entry.rawPacket, Base64.NO_WRAP),
            "gatewayUid" to gatewayUid,
            "receivedAt" to FieldValue.serverTimestamp()
        )

        Tasks.await(firestore.runTransaction { transaction ->
            if (!transaction.get(document).exists()) transaction.set(document, fields)
            true
        })
    }

    private fun hasValidatedInternet(): Boolean {
        val network = connectivity.activeNetwork ?: return false
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
        return isValidatedInternet(capabilities)
    }

    private fun isValidatedInternet(capabilities: NetworkCapabilities): Boolean =
        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)

    override fun close() {
        if (closed) return
        closed = true
        InboundPacketBridge.removeListener(packetListener)
        auth.removeAuthStateListener(authListener)
        try {
            connectivity.unregisterNetworkCallback(networkCallback)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Network callback was already unregistered")
        } catch (e: RuntimeException) {
            Log.e(TAG, "Could not unregister network callback", e)
        }
    }

    private data class PendingSupplyPacket(val packetId: String, val rawPacket: ByteArray)

    private class SupplyPacketOutbox(file: File) {
        private val atomicFile = AtomicFile(file)
        private val entries = LinkedHashMap<String, ByteArray>()

        init {
            load()
        }

        @Synchronized
        fun enqueue(packetId: String, rawPacket: ByteArray): Boolean {
            if (entries.containsKey(packetId)) return false
            if (entries.size >= MAX_OUTBOX_ENTRIES) {
                throw IllegalStateException("Maximum pending packet count ($MAX_OUTBOX_ENTRIES) reached")
            }
            entries[packetId] = rawPacket.copyOf()
            try {
                persist()
            } catch (e: IOException) {
                entries.remove(packetId)
                throw e
            }
            return true
        }

        @Synchronized
        fun firstOrNull(): PendingSupplyPacket? = entries.entries.firstOrNull()?.let {
            PendingSupplyPacket(it.key, it.value.copyOf())
        }

        @Synchronized
        fun hasPending(): Boolean = entries.isNotEmpty()

        @Synchronized
        fun remove(packetId: String) {
            val removed = entries.remove(packetId) ?: return
            try {
                persist()
            } catch (e: IOException) {
                entries[packetId] = removed
                throw e
            }
        }

        private fun load() {
            try {
                atomicFile.openRead().use { input ->
                    val root = org.json.JSONArray(input.readBytes().toString(Charsets.UTF_8))
                    for (index in 0 until root.length()) {
                        val record = root.getJSONObject(index)
                        val packetId = record.getString("packetId")
                        val bytes = Base64.decode(record.getString("rawPacket"), Base64.NO_WRAP)
                        val packet = BitchatPacket.fromBinaryData(bytes)
                        if (packet == null ||
                            packet.type != MessageType.SUPPLY_EXCHANGE.value ||
                            SupplyExchangePacket.decode(packet.payload) == null ||
                            PacketIdUtil.computeIdHex(packet) != packetId
                        ) {
                            Log.e(TAG, "Discarding invalid persisted supply packet ${packetId.take(8)}")
                            continue
                        }
                        entries[packetId] = bytes
                        if (entries.size == MAX_OUTBOX_ENTRIES) break
                    }
                }
            } catch (_: FileNotFoundException) {
                // First run: there is no outbox to restore.
            } catch (e: Exception) {
                Log.e(TAG, "Could not restore the durable supply outbox", e)
                throw IllegalStateException("Could not restore durable supply outbox", e)
            }
        }

        private fun persist() {
            val root = org.json.JSONArray()
            entries.forEach { (packetId, bytes) ->
                root.put(
                    org.json.JSONObject()
                        .put("packetId", packetId)
                        .put("rawPacket", Base64.encodeToString(bytes, Base64.NO_WRAP))
                )
            }
            var stream: java.io.FileOutputStream? = null
            try {
                stream = atomicFile.startWrite()
                stream.write(root.toString().toByteArray(Charsets.UTF_8))
                atomicFile.finishWrite(stream)
            } catch (e: IOException) {
                if (stream != null) atomicFile.failWrite(stream)
                throw e
            }
        }
    }

    private companion object {
        const val TAG = "MeshSupplyGateway"
        const val COLLECTION = "mesh_supply_packets"
        const val SCHEMA_VERSION = 1
        const val MAX_OUTBOX_ENTRIES = 1_000
        const val OUTBOX_FILE = "mesh_supply_outbox.json"
    }
}
