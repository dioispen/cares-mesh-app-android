package com.bitchat.android.mesh

import android.os.Build
import com.bitchat.android.model.NoisePayload
import com.bitchat.android.model.NoisePayloadType
import com.bitchat.android.model.PrivateMessagePacket
import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.noise.NoisePeerIdentity
import com.bitchat.android.noise.NoiseSessionManager
import com.bitchat.android.noise.southernstorm.protocol.Noise
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.service.TransportBridgeService
import com.bitchat.android.testsupport.FakeAndroidKeyStore
import com.bitchat.android.testsupport.ResourcelessContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * What a private message looks like on the air (#9, #55): the real [BluetoothMeshService]
 * send path, with only the radio replaced by a recorder.
 *
 * The Flutter chat reaches this path through upstream alone (`chat_sendMessage` →
 * `ChatViewModel.sendMessage` → `MessageRouter.sendPrivate` → `MeshService.sendPrivateMessage`,
 * see `MessageRouterTest` for the queueing in between), so these tests pin the property #9 asks
 * for at the last hop: a private message is addressed to its recipient, never to the broadcast
 * address, and its payload is Noise ciphertext that only the recipient's session opens.
 * Mesh product code is not changed for this; the radio is swapped in by reflection, and so is the
 * mesh's coroutine scope: its sends then run on a test scheduler, so a test runs a send to its end
 * and reads everything it put on the air, instead of waiting on the clock for what may follow.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class PrivateMessageWireTest {

    private data class Identity(val privateKey: ByteArray, val publicKey: ByteArray, val peerID: String)

    private lateinit var mesh: BluetoothMeshService
    private val sends = TestCoroutineScheduler()
    private val onAir = ConcurrentLinkedQueue<BitchatPacket>()
    private val bob = identity()
    private val bobNoise = NoiseSessionManager(
        localStaticPrivateKey = bob.privateKey,
        localStaticPublicKey = bob.publicKey,
        localPeerID = bob.peerID
    )

    @Before
    fun setUp() {
        FakeAndroidKeyStore.install()
        mesh = BluetoothMeshService(ResourcelessContext(RuntimeEnvironment.getApplication()))
        val radio = mock<BluetoothConnectionManager>()
        whenever(radio.broadcastPacket(any())).thenAnswer { invocation ->
            onAir.add((invocation.arguments[0] as RoutedPacket).packet)
            true
        }
        replaceField(mesh, "connectionManager", radio)
        replaceField(mesh, "serviceScope", CoroutineScope(StandardTestDispatcher(sends) + SupervisorJob()))
    }

    @After
    fun tearDown() {
        bobNoise.shutdown()
        TransportBridgeService.unregister("BLE")
        FakeAndroidKeyStore.uninstall()
    }

    @Test
    fun `a private message is addressed to its recipient and Noise encrypted`() {
        establishSessionWithBob()

        mesh.sendPrivateMessage(SECRET, bob.peerID, "bob", "msg-1")
        sends.advanceUntilIdle()

        val packet = nextOnAir() ?: throw AssertionError("nothing was sent")
        assertEquals(MessageType.NOISE_ENCRYPTED.value, packet.type)
        assertArrayEquals(hex(bob.peerID), packet.recipientID)
        assertFalse(
            "a private message must never go to the broadcast address",
            packet.recipientID!!.contentEquals(SpecialRecipients.BROADCAST)
        )
        assertFalse("the text must not be readable on the air", packet.payload.contains(SECRET.toByteArray()))

        // Only Bob's end of the session opens it, and it is exactly the private message sent.
        val payload = NoisePayload.decode(bobNoise.decrypt(packet.payload, mesh.myPeerID))
        assertNotNull(payload)
        assertEquals(NoisePayloadType.PRIVATE_MESSAGE, payload!!.type)
        val message = PrivateMessagePacket.decode(payload.data)
        assertEquals("msg-1", message?.messageID)
        assertEquals(SECRET, message?.content)
        assertNull("nothing else was sent", nextOnAir())
    }

    @Test
    fun `without a Noise session the text is not sent at all, only a handshake to the recipient`() {
        mesh.sendPrivateMessage(SECRET, bob.peerID, "bob", "msg-2")
        sends.advanceUntilIdle()

        val packet = nextOnAir() ?: throw AssertionError("expected a handshake")
        assertEquals(MessageType.NOISE_HANDSHAKE.value, packet.type)
        assertArrayEquals(hex(bob.peerID), packet.recipientID)
        assertFalse(packet.payload.contains(SECRET.toByteArray()))
        assertNull("the message itself is not sent before a session exists", nextOnAir())
    }

    /** Noise XX between the mesh's own identity and Bob, driven through the mesh's public API. */
    private fun establishSessionWithBob() {
        mesh.initiateNoiseHandshake(bob.peerID)
        val message1 = nextOnAir() ?: throw AssertionError("no handshake was sent")
        assertEquals(MessageType.NOISE_HANDSHAKE.value, message1.type)
        val message2 = bobNoise.processHandshakeMessage(mesh.myPeerID, message1.payload)!!
        val message3 = meshEncryption().processHandshakeMessage(message2, bob.peerID)!!
        assertNull(bobNoise.processHandshakeMessage(mesh.myPeerID, message3))
        assertTrue(mesh.hasEstablishedSession(bob.peerID))
        onAir.clear()
    }

    private fun meshEncryption(): com.bitchat.android.crypto.EncryptionService =
        readField(mesh, "encryptionService")

    /** The next packet put on the air by what has run so far (sends run with [sends]); null if none. */
    private fun nextOnAir(): BitchatPacket? = onAir.poll()

    private fun ByteArray.contains(needle: ByteArray): Boolean =
        (0..size - needle.size).any { start -> needle.indices.all { this[start + it] == needle[it] } }

    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun replaceField(target: Any, name: String, value: Any) {
        target.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(target, value)
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> readField(target: Any, name: String): T =
        target.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(target) as T

    private fun identity(): Identity {
        val dh = Noise.createDH("25519")
        return try {
            dh.generateKeyPair()
            val privateKey = ByteArray(32)
            val publicKey = ByteArray(32)
            dh.getPrivateKey(privateKey, 0)
            dh.getPublicKey(publicKey, 0)
            Identity(privateKey, publicKey, NoisePeerIdentity.derivePeerID(publicKey)!!)
        } finally {
            dh.destroy()
        }
    }

    private companion object {
        const val SECRET = "meet at the north shelter at 9"
    }
}
