package com.bitchat.android.gateway

import android.util.Log
import com.google.android.gms.tasks.Task
import com.google.firebase.Timestamp
import com.google.firebase.firestore.Blob
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * [MeshSupplyUploader] backed by Firestore：一筆封包一次 `set` 到 `mesh_supply_packets/{packetId}`，
 * 不先讀。規則只允許 create、不允許 update，所以同一個 Packet ID 已被別的 Gateway 寫過時會得到
 * PERMISSION_DENIED，[MeshSupplyGateway] 視同已上傳——這就是去重，省下 Spark 方案的讀取額度。
 */
class FirestoreMeshSupplyUploader(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val timeoutMs: Long = UPLOAD_TIMEOUT_MS
) : MeshSupplyUploader {

    override suspend fun upload(packet: GatewaySupplyPacket, gatewayUid: String): UploadResult = try {
        val write = firestore.collection(MESH_SUPPLY_PACKETS)
            .document(packet.packetId)
            .set(meshSupplyDocument(packet, gatewayUid))
        if (withTimeoutOrNull(timeoutMs) { write.awaitCompletion() } != null) {
            UploadResult.UPLOADED
        } else {
            UploadResult.TRANSIENT_FAILURE
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        classifyUploadFailure(e).also { Log.w(TAG, "mesh_supply_packets write failed (${errorCode(e)}): $it") }
    }

    private companion object {
        const val TAG = "FirestoreMeshSupplyUploader"
        const val UPLOAD_TIMEOUT_MS = 30_000L

        fun errorCode(e: Exception): String = (e as? FirebaseFirestoreException)?.code?.name ?: e.javaClass.simpleName
    }
}

internal const val MESH_SUPPLY_PACKETS = "mesh_supply_packets"
internal const val MESH_SUPPLY_SCHEMA_VERSION = 1

/**
 * `mesh_supply_packets/{packetId}` 文件（docs/MESH_SUPPLY_PACKETS.md）。`firestore.rules` 只接受
 * 這些鍵。`exchangeId` 與發送者本人寫進 `supply_requests`／`supply_pledges` 的文件 ID 相同，
 * 後台靠它去重。
 */
internal fun meshSupplyDocument(packet: GatewaySupplyPacket, gatewayUid: String): Map<String, Any?> = mapOf(
    "schemaVersion" to MESH_SUPPLY_SCHEMA_VERSION,
    "packetId" to packet.packetId,
    "exchangeId" to packet.supply.exchangeId,
    "action" to packet.supply.action.value,
    "originPeerId" to packet.senderPeerID,
    "itemId" to packet.supply.itemId,
    "itemName" to packet.supply.itemName,
    "quantity" to packet.supply.quantity,
    "unit" to packet.supply.unit,
    "createdAt" to Timestamp(packet.createdAtMs / 1000, ((packet.createdAtMs % 1000) * 1_000_000).toInt()),
    "uploadedAt" to FieldValue.serverTimestamp(),
    "gatewayUid" to gatewayUid,
    "rawPacket" to Blob.fromBytes(packet.rawPacket)
)

private suspend fun Task<*>.awaitCompletion(): Unit = suspendCancellableCoroutine { continuation ->
    addOnCompleteListener { task ->
        val error = task.exception
        when {
            error != null -> continuation.resumeWithException(error)
            task.isCanceled -> continuation.resumeWithException(IllegalStateException("Firestore write was cancelled"))
            else -> continuation.resume(Unit)
        }
    }
}
