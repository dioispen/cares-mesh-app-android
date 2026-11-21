package com.bitchat.android.sync

import android.os.Build
import com.bitchat.android.model.RequestSyncPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.SpecialRecipients
import com.bitchat.android.service.HealthReportBroadcast
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.security.SecureRandom

/**
 * P0-3（四機試跑 2026-11-18 §7.1）：Reporter 自己最新一筆已簽章的 Health Report 存到磁碟，
 * app 重啟後原封不動放回同步暫存，之後才連上的鄰居經同步補到。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class OwnHealthReportKeeperTest {

    private val myPeerID = "0102030405060708"
    private val otherPeerID = "a1a2a3a4a5a6a7a8"
    private val requester = "c1c2c3c4c5c6c7c8"

    private var now = 1_800_000_000_000L
    private val signingKey = Ed25519PrivateKeyParameters(SecureRandom())
    private val store = InMemoryStore()
    private val scope = CoroutineScope(SupervisorJob())

    @After
    fun tearDown() {
        scope.cancel()
    }

    /** A fresh keeper over the same storage is what the mesh service gets after an app restart. */
    private fun keeper(peerID: String = myPeerID) = OwnHealthReportKeeper(peerID, store, nowMs = { now })

    @Test
    fun `gives back after a restart the very packet that was signed and broadcast`() = runBlocking {
        val sent = signed(healthReport(myPeerID, now - 1_000))
        keeper().keep(sent)

        val restored = keeper().latest()

        assertEquals(sent, restored)
        assertEquals(PacketIdUtil.computeIdHex(sent), PacketIdUtil.computeIdHex(restored!!))
        assertArrayEquals(sent.toBinaryData(padding = false), restored.toBinaryData(padding = false))
        assertTrue(verifies(restored))
    }

    @Test
    fun `keeps only our own signed broadcast Health Reports`() = runBlocking {
        val keeper = keeper()

        keeper.keep(signed(healthReport(otherPeerID, now)))
        keeper.keep(signed(healthReport(myPeerID, now).copy(type = MessageType.ANNOUNCE.value)))
        keeper.keep(signed(healthReport(myPeerID, now).copy(type = MessageType.MESSAGE.value)))
        keeper.keep(healthReport(myPeerID, now)) // unsigned
        keeper.keep(signed(healthReport(myPeerID, now, recipient = hex(otherPeerID))))

        assertNull(store.slot)
        assertNull(keeper.latest())
    }

    @Test
    fun `keeps a report addressed to everyone`() = runBlocking {
        val sent = signed(healthReport(myPeerID, now, recipient = SpecialRecipients.BROADCAST))

        keeper().keep(sent)

        assertEquals(sent, keeper().latest())
    }

    @Test
    fun `a newer report replaces the kept one and an older one does not`() = runBlocking {
        val older = signed(healthReport(myPeerID, now - 10_000, status = 1))
        val newer = signed(healthReport(myPeerID, now - 5_000, status = 2))
        val keeper = keeper()

        keeper.keep(older)
        keeper.keep(newer)
        keeper.keep(older)

        assertEquals(newer, keeper.latest())
    }

    @Test
    fun `expiry runs from the original timestamp, as in the sync store`() = runBlocking {
        val sent = signed(healthReport(myPeerID, now))
        keeper().keep(sent)

        now += AppConstants.Sync.HEALTH_REPORT_RETENTION_MS
        assertEquals(sent, keeper().latest())

        now += 1
        assertNull(keeper().latest())
        assertNull(store.slot) // an expired record is erased, not kept on disk
    }

    @Test
    fun `does not keep a report that is already expired when sent`() = runBlocking {
        keeper().keep(signed(healthReport(myPeerID, now - AppConstants.Sync.HEALTH_REPORT_RETENTION_MS - 1)))

        assertNull(store.slot)
    }

    @Test
    fun `a report kept under another identity is not restored and is erased`() = runBlocking {
        keeper().keep(signed(healthReport(myPeerID, now)))

        // A panic wipe or a reinstall gives the device a new peerID
        assertNull(keeper(peerID = otherPeerID).latest())
        assertNull(store.slot)
    }

    @Test
    fun `an unreadable record is erased`() = runBlocking {
        store.slot = byteArrayOf(1, 2, 3)

        assertNull(keeper().latest())
        assertNull(store.slot)
    }

    @Test
    fun `clear erases the kept report`() = runBlocking {
        val keeper = keeper()
        keeper.keep(signed(healthReport(myPeerID, now)))

        keeper.clear()

        assertNull(store.slot)
        assertNull(keeper.latest())
    }

    @Test
    fun `a report still on its way to disk when clear runs is not written after it`() {
        val io = StandardTestDispatcher()
        val keeper = OwnHealthReportKeeper(myPeerID, store, { now }, io)

        // Without a clear in between, the write lands once the I/O thread runs
        CoroutineScope(Dispatchers.Unconfined).launch { keeper.keep(signed(healthReport(myPeerID, now - 1_000))) }
        io.scheduler.advanceUntilIdle()
        assertNotNull(store.slot)

        // Sent, waiting for the I/O thread, when the panic wipe runs
        val keeping = CoroutineScope(Dispatchers.Unconfined).launch { keeper.keep(signed(healthReport(myPeerID, now))) }
        keeper.clear()
        io.scheduler.advanceUntilIdle()

        assertTrue(keeping.isCompleted)
        assertNull(store.slot)
    }

    @Test
    fun `after a restart sync serves the kept report as the original signed packet`() = runBlocking {
        val sent = signed(healthReport(myPeerID, now - 60_000))
        keeper().keep(sent)

        // Restarted: the sync store starts empty and is given what was kept
        val replies = mutableListOf<Pair<String, BitchatPacket>>()
        val gossip = gossipSyncManager(replies)
        keeper().latest()?.let(gossip::onPublicPacketSeen)
        gossip.handleRequestSync(requester, emptyRequest())

        val (to, served) = replies.single { it.second.type == MessageType.HEALTH_REPORT.value }
        assertEquals(requester, to)
        assertEquals(sent.copy(ttl = AppConstants.SYNC_TTL_HOPS), served)
        assertEquals(PacketIdUtil.computeIdHex(sent), PacketIdUtil.computeIdHex(served))
        assertTrue(verifies(served))
    }

    private fun gossipSyncManager(replies: MutableList<Pair<String, BitchatPacket>>) =
        GossipSyncManager(
            myPeerID = myPeerID,
            scope = scope,
            configProvider = object : GossipSyncManager.ConfigProvider {
                override fun seenCapacity(): Int = 100
                override fun gcsMaxBytes(): Int = SyncDefaults.DEFAULT_FILTER_BYTES
                override fun gcsTargetFpr(): Double = FPR
            },
            nowMs = { now }
        ).apply {
            delegate = object : GossipSyncManager.Delegate {
                override fun sendPacket(packet: BitchatPacket) {}
                override fun sendPacketToPeer(peerID: String, packet: BitchatPacket) {
                    replies += peerID to packet
                }
                override fun signPacketForBroadcast(packet: BitchatPacket): BitchatPacket = packet
            }
        }

    private fun emptyRequest(): RequestSyncPacket =
        RequestSyncPacket(p = GCSFilter.deriveP(FPR), m = 1, data = ByteArray(0))

    /** The packet HealthReportBroadcast puts on the mesh, before BluetoothMeshService signs it. */
    private fun healthReport(
        sender: String,
        timestamp: Long,
        status: Int = 1,
        recipient: ByteArray? = null
    ): BitchatPacket = HealthReportBroadcast
        .packet(sender, byteArrayOf(2, status.toByte()) + ByteArray(18) { it.toByte() }, timestamp = timestamp)
        .copy(recipientID = recipient)

    private fun signed(packet: BitchatPacket): BitchatPacket {
        val data = packet.toBinaryDataForSigning()!!
        val signer = Ed25519Signer().apply {
            init(true, signingKey)
            update(data, 0, data.size)
        }
        return packet.copy(signature = signer.generateSignature())
    }

    private fun verifies(packet: BitchatPacket): Boolean {
        val data = packet.toBinaryDataForSigning()!!
        return Ed25519Signer().run {
            init(false, signingKey.generatePublicKey())
            update(data, 0, data.size)
            verifySignature(packet.signature)
        }
    }

    private fun hex(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private class InMemoryStore : OwnHealthReportStore {
        var slot: ByteArray? = null
        override fun read(): ByteArray? = slot?.copyOf()
        override fun write(encoded: ByteArray) {
            slot = encoded.copyOf()
        }
        override fun clear() {
            slot = null
        }
    }

    private companion object {
        const val FPR = 0.01
    }
}
