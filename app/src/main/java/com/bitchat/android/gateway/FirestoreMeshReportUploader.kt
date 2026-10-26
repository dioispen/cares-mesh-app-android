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
 * [MeshReportUploader] backed by Firestore (ADR-0009): one `set` of `mesh_reports/{reporterHandle}`
 * per report, overwriting the whole document (never a merge) and never reading first, to spare the
 * Spark plan's read quota. Thin on purpose: [MeshGateway] decides what to upload; this only shapes
 * the document and sorts Firestore's answer into an [UploadResult].
 *
 * Firestore's persistence stays on (Flutter's SOS screen relies on its offline cache), so a write
 * cut off by a lost connection can sit in the SDK's on-disk queue until it is sent; ADR-0009
 * accepts that.
 */
class FirestoreMeshReportUploader(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val timeoutMs: Long = UPLOAD_TIMEOUT_MS
) : MeshReportUploader {

    override suspend fun upload(report: GatewayReport, gatewayUid: String): UploadResult = try {
        val write = firestore.collection(MESH_REPORTS)
            .document(report.reporterHandle)
            .set(meshReportDocument(report, gatewayUid))
        // A write completes only once the server acknowledges it; with the connection gone it
        // would wait for as long as that lasts.
        if (withTimeoutOrNull(timeoutMs) { write.awaitCompletion() } != null) {
            UploadResult.UPLOADED
        } else {
            UploadResult.TRANSIENT_FAILURE
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        classifyUploadFailure(e).also { Log.w(TAG, "mesh_reports write failed (${errorCode(e)}): $it") }
    }

    private companion object {
        const val TAG = "FirestoreMeshReportUploader"
        const val UPLOAD_TIMEOUT_MS = 30_000L

        fun errorCode(e: Exception): String = (e as? FirebaseFirestoreException)?.code?.name ?: e.javaClass.simpleName
    }
}

internal const val MESH_REPORTS = "mesh_reports"
internal const val MESH_REPORT_SCHEMA_VERSION = 1

/**
 * The `mesh_reports/{reporterHandle}` document: the Broadcast Tier as received, plus what an
 * Administrator needs to audit it and, later, to verify its signature (MESH_GATEWAY.md §5.2).
 * `firestore.rules` accepts exactly these keys.
 */
internal fun meshReportDocument(report: GatewayReport, gatewayUid: String): Map<String, Any?> = mapOf(
    "schemaVersion" to MESH_REPORT_SCHEMA_VERSION,
    "reporterHandle" to report.reporterHandle,
    "status" to report.payload.status.label,
    "sos" to report.payload.sos,
    "geohash" to report.payload.geohash.ifEmpty { null },
    "reportTime" to Timestamp(report.reportTimeMs / 1000, 0),
    "uploadedAt" to FieldValue.serverTimestamp(),
    "gatewayUid" to gatewayUid,
    "senderPeerId" to report.senderPeerID,
    "rawPacket" to Blob.fromBytes(report.rawPacket),
    "announcement" to report.announcement?.let(Blob::fromBytes)
)

/**
 * PERMISSION_DENIED is the rules refusing the write, usually because another gateway got there
 * first with this report or a newer one. Everything else may go through on a later try.
 */
internal fun classifyUploadFailure(e: Exception): UploadResult =
    if ((e as? FirebaseFirestoreException)?.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) {
        UploadResult.PERMISSION_DENIED
    } else {
        UploadResult.TRANSIENT_FAILURE
    }

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
