package com.bitchat.android.gateway

import android.os.Build
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.google.firebase.Timestamp
import com.google.firebase.firestore.Blob
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.FirebaseFirestoreException.Code
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException

/**
 * The thin Firestore adapter of the Gateway (#111): the document it writes matches what
 * `firestore.rules` accepts for `mesh_reports`, and Firestore's errors are sorted into success,
 * PERMISSION_DENIED and transient. The write itself is left to the device acceptance tests.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class FirestoreMeshReportUploaderTest {

    private val raw = byteArrayOf(0x01, 0x30, 0x07)
    private val announce = byteArrayOf(0x01, 0x01, 0x07)

    @Test
    fun `the document carries exactly the fields the rules accept`() {
        val document = meshReportDocument(report(), "uid-gateway")

        assertEquals(
            setOf(
                "schemaVersion", "reporterHandle", "status", "sos", "geohash", "reportTime",
                "uploadedAt", "gatewayUid", "senderPeerId", "rawPacket", "announcement"
            ),
            document.keys
        )
        assertEquals(1, document["schemaVersion"])
        assertEquals("abcdef012345", document["reporterHandle"])
        assertEquals("重傷", document["status"])
        assertEquals(true, document["sos"])
        assertEquals("wsqqqm", document["geohash"])
        assertEquals(Timestamp(1_700_000_000L, 0), document["reportTime"])
        assertEquals(FieldValue.serverTimestamp(), document["uploadedAt"])
        assertEquals("uid-gateway", document["gatewayUid"])
        assertEquals("0102030405060708", document["senderPeerId"])
        assertArrayEquals(raw, (document["rawPacket"] as Blob).toBytes())
        assertArrayEquals(announce, (document["announcement"] as Blob).toBytes())
    }

    @Test
    fun `no location and no announcement are written as null`() {
        val document = meshReportDocument(
            report(status = HealthStatus.UNDECLARED, geohash = "", announcement = null),
            "uid-gateway"
        )

        assertEquals("未宣告", document["status"])
        assertNull(document["geohash"])
        assertNull(document["announcement"])
        assertEquals(true, document.containsKey("geohash") && document.containsKey("announcement"))
    }

    @Test
    fun `every Status is written with the label health_reports uses`() {
        val labels = HealthStatus.values().map { status ->
            meshReportDocument(report(status = status, sos = status != HealthStatus.SAFE), "u")["status"]
        }

        assertEquals(listOf("安全", "輕傷", "重傷", "未宣告"), labels)
    }

    @Test
    fun `PERMISSION_DENIED is told apart from transient errors`() {
        assertEquals(UploadResult.PERMISSION_DENIED, classifyUploadFailure(firestoreError(Code.PERMISSION_DENIED)))

        for (code in listOf(Code.UNAVAILABLE, Code.DEADLINE_EXCEEDED, Code.UNAUTHENTICATED, Code.INTERNAL, Code.ABORTED)) {
            assertEquals(code.name, UploadResult.TRANSIENT_FAILURE, classifyUploadFailure(firestoreError(code)))
        }
        assertEquals(UploadResult.TRANSIENT_FAILURE, classifyUploadFailure(IOException("offline")))
    }

    private fun firestoreError(code: Code) = FirebaseFirestoreException(code.name, code)

    private fun report(
        status: HealthStatus = HealthStatus.SEVERE,
        sos: Boolean = true,
        geohash: String = "wsqqqm",
        announcement: ByteArray? = announce
    ) = GatewayReport(
        payload = HealthReportPayload("abcdef012345", status, geohash, 1_700_000_000_000L, sos),
        senderPeerID = "0102030405060708",
        rawPacket = raw,
        announcement = announcement
    )
}
