package com.bitchat.android.gateway

import com.bitchat.android.protocol.HealthReportPayload

/**
 * Someone else's Health Report this phone may relay, as handed over by the protocol hook
 * (`VerifiedHealthReportBridge`) at the moment it was received.
 */
class GatewayReport(
    val payload: HealthReportPayload,
    /** The packet header's senderID: 16 lowercase hex characters. */
    val senderPeerID: String,
    /** The HEALTH_REPORT packet as received, content tag and signature included (ADR-0009). */
    val rawPacket: ByteArray,
    /** The sender's verified, signed ANNOUNCE from the Health Report key cache; null when it has none. */
    val announcement: ByteArray?
) {
    val reporterHandle: String get() = payload.reporterHandle
    val reportTimeMs: Long get() = payload.reportTimeMillis
}

/** How one write of `mesh_reports/{reporterHandle}` ended. */
enum class UploadResult {
    UPLOADED,

    /**
     * The rules refused the write. Usually another gateway already wrote this report or a newer
     * one (`reportTime` must strictly increase), so it counts as done.
     */
    PERMISSION_DENIED,

    /** Anything that may succeed later: no connection, timeout, server unavailable. */
    TRANSIENT_FAILURE
}

/** The Gateway's only output: Firestore in production, a fake in tests. */
interface MeshReportUploader {
    suspend fun upload(report: GatewayReport, gatewayUid: String): UploadResult
}
