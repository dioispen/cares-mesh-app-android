package com.bitchat.android.gateway

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import com.bitchat.android.mesh.VerifiedHealthReport
import com.bitchat.android.mesh.VerifiedHealthReportBridge
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.protocol.MessageType
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The Gateway's Android wiring lives exactly as long as the mesh service (#112): what start()
 * registers, stop() removes — the default-network callback, the sign-in listener and the protocol
 * hook — so a restarted service never leaks or doubles them.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class MeshGatewayRuntimeTest {

    private val connectivity = RuntimeEnvironment.getApplication()
        .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val auth = mock<FirebaseAuth>()
    private val uploads = mutableListOf<GatewayReport>()
    private val uploader = object : MeshReportUploader {
        override suspend fun upload(report: GatewayReport, gatewayUid: String): UploadResult {
            uploads += report
            return UploadResult.UPLOADED
        }
    }

    @Test
    fun `start registers the network callback, the sign-in listener and the hook, and stop removes them all`() = runTest {
        val gateway = MeshGateway(uploader, { 1_700_000_100_000L }, backgroundScope)
        val runtime = MeshGatewayRuntime(auth, connectivity, gateway, backgroundScope)
        val callbacksBefore = shadowOf(connectivity).networkCallbacks.size
        val hooksBefore = VerifiedHealthReportBridge.listenerCount

        runtime.start()

        assertEquals(callbacksBefore + 1, shadowOf(connectivity).networkCallbacks.size)
        assertEquals(hooksBefore + 1, VerifiedHealthReportBridge.listenerCount)
        val authListener = argumentCaptor<FirebaseAuth.AuthStateListener>()
            .apply { verify(auth).addAuthStateListener(capture()) }
            .firstValue

        runtime.stop()

        assertEquals(callbacksBefore, shadowOf(connectivity).networkCallbacks.size)
        assertEquals(hooksBefore, VerifiedHealthReportBridge.listenerCount)
        verify(auth).removeAuthStateListener(authListener)
    }

    @Test
    fun `a verified report reaches the gateway as received`() = runTest {
        val gateway = MeshGateway(uploader, { 1_700_000_100_000L }, backgroundScope)
        val runtime = MeshGatewayRuntime(auth, connectivity, gateway, backgroundScope)
        runtime.start()
        gateway.onSignedIn("uid-gateway")
        gateway.onNetworkChanged(true)
        val packet = healthReportPacket()

        VerifiedHealthReportBridge.publish(verified(packet))
        runCurrent()

        val uploaded = uploads.single()
        assertArrayEquals(packet.toBinaryData(padding = false), uploaded.rawPacket)
        assertEquals(BroadcastContentTag.HEALTH_REPORT.value, BitchatPacket.fromBinaryData(uploaded.rawPacket)!!.payload.first())
        assertEquals("0102030405060708", uploaded.senderPeerID)
        runtime.stop()
    }

    private fun verified(packet: BitchatPacket) = VerifiedHealthReport(
        packet = packet,
        report = HealthReportPayload.decode(packet.payload.copyOfRange(1, packet.payload.size))!!,
        senderPeerID = "0102030405060708"
    )

    private fun healthReportPacket(reportTimeMs: Long = 1_700_000_000_000L) = BitchatPacket(
        version = 1u,
        type = MessageType.HEALTH_REPORT.value,
        senderID = ByteArray(8) { (it + 1).toByte() },
        timestamp = reportTimeMs.toULong(),
        payload = byteArrayOf(BroadcastContentTag.HEALTH_REPORT.value) +
            HealthReportPayload("abcdef012345", HealthStatus.SEVERE, "wsqqqm", reportTimeMs, sos = true).encode(),
        signature = ByteArray(64) { 7 },
        ttl = 3u
    )
}
