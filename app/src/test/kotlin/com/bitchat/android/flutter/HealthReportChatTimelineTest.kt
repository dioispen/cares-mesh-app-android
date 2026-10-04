package com.bitchat.android.flutter

import android.os.Build
import com.bitchat.android.mesh.MessageHandler
import com.bitchat.android.mesh.MessageHandlerDelegate
import com.bitchat.android.mesh.PeerInfo
import com.bitchat.android.model.BitchatMessage
import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.protocol.MessageType
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.Date
import kotlin.time.Duration.Companion.seconds

/**
 * Pins the Health Report decision against the real producer: whatever line
 * MessageHandler.handleHealthReport() hands the chat delegate must not reach the Flutter chat
 * timeline. If the producer's text changes, this fails instead of the report silently
 * reappearing in the chat room.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class HealthReportChatTimelineTest {

    private val peerID = "0102030405060708"
    private val me = ChatSelf(peerID = "1111222233334444", nickname = "me")

    @Test
    fun `health report delivered by MessageHandler is left out of the chat timeline`() = runTest(timeout = 10.seconds) {
        val delegate = mock<MessageHandlerDelegate>()
        whenever(delegate.getPeerInfo(peerID)).thenReturn(verifiedPeer())
        val handler = MessageHandler(me.peerID, RuntimeEnvironment.getApplication())
        handler.delegate = delegate

        handler.handleHealthReport(RoutedPacket(healthReportPacket(), peerID, "direct-link"))

        val delivered = argumentCaptor<BitchatMessage>()
            .apply { verify(delegate).onMessageReceived(capture()) }
            .firstValue
        val chatLine = BitchatMessage(
            id = "CHAT",
            sender = "alice",
            content = "anyone near the station?",
            timestamp = Date(),
            senderPeerID = peerID
        )

        val event = ChatSerialization.publicMessagesEvent(listOf(delivered, chatLine), me)

        @Suppress("UNCHECKED_CAST")
        val ids = (event["messages"] as List<Map<String, Any?>>).map { it["id"] }
        assertEquals(listOf("CHAT"), ids)
    }

    private fun verifiedPeer() = PeerInfo(
        id = peerID,
        nickname = "reporter",
        isConnected = true,
        isDirectConnection = true,
        noisePublicKey = ByteArray(32) { 0x0B },
        signingPublicKey = ByteArray(32) { 0x0A },
        isVerifiedNickname = true,
        lastSeen = System.currentTimeMillis()
    )

    private fun healthReportPacket(): BitchatPacket {
        val payload = HealthReportPayload.fromLocation(
            reporterHandle = "abcdef012345",
            status = HealthStatus.SEVERE,
            lat = 23.97,
            lng = 120.97,
            reportTimeMillis = 1_700_000_000_000L
        ).encode()
        return BitchatPacket(
            type = MessageType.HEALTH_REPORT.value,
            senderID = ByteArray(8) { (it + 1).toByte() },
            timestamp = System.currentTimeMillis().toULong(),
            payload = payload,
            ttl = 3u
        )
    }
}
