package com.bitchat.android.gateway

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.os.Looper
import com.bitchat.android.mesh.VerifiedHealthReport
import com.bitchat.android.mesh.VerifiedHealthReportBridge
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.service.MeshServicePreferences
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
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

    @Before
    fun setUp() {
        RuntimeEnvironment.getApplication()
            .getSharedPreferences("bitchat_mesh_service_prefs", Context.MODE_PRIVATE)
            .edit().clear().commit()
        MeshServicePreferences.init(RuntimeEnvironment.getApplication())
    }

    @Test
    fun `the Gateway switch is on by default and survives a restart`() {
        assertTrue(MeshServicePreferences.isGatewayEnabled())

        MeshServicePreferences.setGatewayEnabled(false)
        MeshServicePreferences.init(RuntimeEnvironment.getApplication())

        assertFalse(MeshServicePreferences.isGatewayEnabled())
    }

    @Test
    fun `the gateway follows the stored switch, also while it runs`() = runTest {
        MeshServicePreferences.setGatewayEnabled(false)
        val gateway = MeshGateway(uploader, { 1_700_000_100_000L }, backgroundScope)
        val runtime = MeshGatewayRuntime(auth, connectivity, gateway, backgroundScope)
        runtime.start()
        gateway.onSignedIn("uid-gateway")
        gateway.onNetworkChanged(true)

        VerifiedHealthReportBridge.publish(verified(healthReportPacket(reportTimeMs = 1_700_000_000_000L)))
        runCurrent()
        assertTrue("switched off when the service started", uploads.isEmpty())

        MeshServicePreferences.setGatewayEnabled(true) // 使用者在設定頁打開
        shadowOf(Looper.getMainLooper()).idle()
        VerifiedHealthReportBridge.publish(verified(healthReportPacket(reportTimeMs = 1_700_000_050_000L)))
        runCurrent()
        assertEquals(1, uploads.size)

        MeshServicePreferences.setGatewayEnabled(false)
        shadowOf(Looper.getMainLooper()).idle()
        VerifiedHealthReportBridge.publish(verified(healthReportPacket(reportTimeMs = 1_700_000_090_000L)))
        runCurrent()
        assertEquals("switched off again", 1, uploads.size)
        runtime.stop()
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
    fun `a verified report reaches the gateway as received, with the sender's announcement`() = runTest {
        val announce = announcePacket()
        val gateway = MeshGateway(uploader, { 1_700_000_100_000L }, backgroundScope)
        val runtime = MeshGatewayRuntime(
            auth, connectivity, gateway, backgroundScope,
            announcementFor = { peerID -> announce.takeIf { peerID == SENDER } }
        )
        runtime.start()
        gateway.onSignedIn("uid-gateway")
        gateway.onNetworkChanged(true)
        val packet = healthReportPacket()

        VerifiedHealthReportBridge.publish(verified(packet))
        runCurrent()

        val uploaded = uploads.single()
        val received = BitchatPacket.fromBinaryData(uploaded.rawPacket)!!
        assertArrayEquals("content tag kept", packet.payload, received.payload)
        assertEquals(BroadcastContentTag.HEALTH_REPORT.value, received.payload.first())
        assertArrayEquals(packet.signature, received.signature)
        assertArrayEquals(packet.senderID, received.senderID)
        assertEquals(SENDER, uploaded.senderPeerID)
        val announcement = BitchatPacket.fromBinaryData(uploaded.announcement!!)!!
        assertEquals(MessageType.ANNOUNCE.value, announcement.type)
        assertArrayEquals(announce.signature, announcement.signature)
        runtime.stop()
    }

    @Test
    fun `a report whose sender has no cached announcement is uploaded with none`() = runTest {
        val gateway = MeshGateway(uploader, { 1_700_000_100_000L }, backgroundScope)
        val runtime = MeshGatewayRuntime(auth, connectivity, gateway, backgroundScope, announcementFor = { null })
        runtime.start()
        gateway.onSignedIn("uid-gateway")
        gateway.onNetworkChanged(true)

        VerifiedHealthReportBridge.publish(verified(healthReportPacket()))
        runCurrent()

        assertNull(uploads.single().announcement)
        runtime.stop()
    }

    private fun announcePacket() = BitchatPacket(
        version = 1u,
        type = MessageType.ANNOUNCE.value,
        senderID = ByteArray(8) { (it + 1).toByte() },
        timestamp = 1_699_999_000_000L.toULong(),
        payload = byteArrayOf(0x01, 0x04) + "anon".toByteArray(),
        signature = ByteArray(64) { 9 },
        ttl = 7u
    )

    private fun verified(packet: BitchatPacket) = VerifiedHealthReport(
        packet = packet,
        report = HealthReportPayload.decode(packet.payload.copyOfRange(1, packet.payload.size))!!,
        senderPeerID = SENDER
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

    private companion object {
        const val SENDER = "0102030405060708"
    }
}
