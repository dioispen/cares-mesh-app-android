package com.bitchat.android.mesh

import android.os.Build
import com.bitchat.android.model.IdentityAnnouncement
import com.bitchat.android.noise.NoisePeerIdentity
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.util.AppConstants
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * #95：驗 Health Report 簽章的 key 與在線 peer 分開保存。Reporter 離開、被 PeerManager 移除後，
 * 經同步補送來的 Health Report 仍用他最後一次通過驗證的 ANNOUNCE 所帶的 signing key 驗；
 * 超過時間差上限、但簽章與身分綁定都正確的 ANNOUNCE 只把 key 寫進快取。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class SecurityManagerHealthReportSigningKeyTest {

    private val myPeerID = "1111222233334444"
    private val noiseKey = ByteArray(32) { 0x0B }
    private val reporterPeerID = NoisePeerIdentity.derivePeerID(noiseKey)!!
    private val signingKey = ByteArray(32) { 0x0A }
    private val otherSigningKey = ByteArray(32) { 0x0C }
    private val validSignature = ByteArray(64) { 1 }
    private val invalidSignature = ByteArray(64) { 0 }

    private var now = 1_800_000_000_000L
    private lateinit var encryption: SecurityManagerTest.FakeEncryptionService
    private lateinit var delegate: SecurityManagerDelegate
    private lateinit var securityManager: SecurityManager

    @Before
    fun setup() {
        encryption = SecurityManagerTest.FakeEncryptionService()
        delegate = mock()
        whenever(delegate.getPeerInfo(reporterPeerID)).thenReturn(null)
        securityManager = SecurityManager(encryption, myPeerID, nowMs = { now })
        securityManager.delegate = delegate
    }

    @After
    fun tearDown() {
        securityManager.shutdown()
    }

    // Step 1: the key outlives the live peer entry.

    @Test
    fun `health report from a departed reporter verifies with the key from their last announce`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))
        now += AppConstants.Mesh.STALE_PEER_TIMEOUT_MS + 1

        assertTrue(securityManager.validatePacket(healthReport(), reporterPeerID))
        assertArrayEquals(signingKey, encryption.lastVerifyKey)
    }

    @Test
    fun `health report from a reporter never announced is rejected`() {
        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `health report with a bad signature is rejected even with a cached key`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))

        assertFalse(
            securityManager.validatePacket(healthReport(signature = invalidSignature), reporterPeerID)
        )
    }

    @Test
    fun `cached key does not verify broadcast messages or leave`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))

        assertFalse(securityManager.validatePacket(signed(MessageType.MESSAGE), reporterPeerID))
        assertFalse(securityManager.validatePacket(signed(MessageType.LEAVE), reporterPeerID))
    }

    @Test
    fun `live peer key takes precedence over the cached key`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))
        whenever(delegate.getPeerInfo(reporterPeerID)).thenReturn(livePeer(otherSigningKey))

        assertTrue(securityManager.validatePacket(healthReport(), reporterPeerID))
        assertArrayEquals(otherSigningKey, encryption.lastVerifyKey)
    }

    @Test
    fun `cached key expires after the health report retention period`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))

        now += AppConstants.Sync.HEALTH_REPORT_RETENTION_MS + 1

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `clearing all data forgets cached keys`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))

        securityManager.clearAllData()

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
        assertFalse(securityManager.hasCachedHealthReportSigningKey(reporterPeerID))
    }

    @Test
    fun `authenticated announce replaces a conflicting cached key`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))
        whenever(delegate.getAuthenticatedSigningKey(noiseKey)).thenReturn(otherSigningKey)

        assertTrue(
            securityManager.validatePacket(announce(ageMs = 0, signingPublicKey = otherSigningKey), reporterPeerID)
        )

        assertTrue(securityManager.validatePacket(healthReport(), reporterPeerID))
        assertArrayEquals(otherSigningKey, encryption.lastVerifyKey)
    }

    @Test
    fun `unauthenticated announce does not replace a conflicting cached key`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))

        securityManager.validatePacket(announce(ageMs = 0, signingPublicKey = otherSigningKey), reporterPeerID)

        assertTrue(securityManager.validatePacket(healthReport(), reporterPeerID))
        assertArrayEquals(signingKey, encryption.lastVerifyKey)
    }

    // Step 2: a stale but valid announce only teaches the key.

    @Test
    fun `stale but valid announce is dropped yet lets a later health report verify`() {
        val stale = announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000)

        assertFalse(
            "A stale ANNOUNCE must not reach the peer list or be relayed",
            securityManager.validatePacket(stale, reporterPeerID)
        )

        assertTrue(securityManager.validatePacket(healthReport(), reporterPeerID))
        assertArrayEquals(signingKey, encryption.lastVerifyKey)
    }

    @Test
    fun `a stale announce is kept whole so it can be passed on with the report`() {
        val stale = announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000)

        securityManager.validatePacket(stale, reporterPeerID)

        assertEquals(stale, securityManager.healthReportAnnouncementFor(reporterPeerID))
    }

    @Test
    fun `a rejected announce is not kept to be passed on`() {
        securityManager.validatePacket(
            announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000, signature = invalidSignature),
            reporterPeerID
        )

        assertNull(securityManager.healthReportAnnouncementFor(reporterPeerID))
    }

    @Test
    fun `synced announce older than the peer timeout teaches the key but does not prove presence`() {
        val synced = announce(ageMs = AppConstants.Mesh.STALE_PEER_TIMEOUT_MS + 60_000, ttl = AppConstants.SYNC_TTL_HOPS)

        assertFalse(
            "A relay's lingering copy must not bring a departed sender back into the peer list",
            securityManager.validatePacket(synced, reporterPeerID)
        )

        assertTrue(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `announce older than the peer timeout with hops left is still accepted for clock skew`() {
        val relayed = announce(ageMs = AppConstants.Mesh.STALE_PEER_TIMEOUT_MS + 60_000, ttl = 3u)

        assertTrue(securityManager.validatePacket(relayed, reporterPeerID))
    }

    @Test
    fun `stale announce with a bad signature teaches nothing`() {
        securityManager.validatePacket(
            announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000, signature = invalidSignature),
            reporterPeerID
        )

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `stale announce whose peer ID is not derived from its Noise key teaches nothing`() {
        securityManager.validatePacket(
            announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000, noisePublicKey = ByteArray(32) { 0x6B }),
            reporterPeerID
        )

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `stale announce conflicting with the persisted authenticated key teaches nothing`() {
        whenever(delegate.getAuthenticatedSigningKey(noiseKey)).thenReturn(otherSigningKey)

        securityManager.validatePacket(announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000), reporterPeerID)

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `stale announce conflicting with the live peer key teaches nothing`() {
        whenever(delegate.getPeerInfo(reporterPeerID)).thenReturn(livePeer(otherSigningKey))
        securityManager.validatePacket(announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000), reporterPeerID)

        whenever(delegate.getPeerInfo(reporterPeerID)).thenReturn(null)

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `stale announce conflicting with an already cached key does not replace it`() {
        assertTrue(securityManager.validatePacket(announce(ageMs = 0), reporterPeerID))

        securityManager.validatePacket(
            announce(ageMs = AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000, signingPublicKey = otherSigningKey),
            reporterPeerID
        )

        assertTrue(securityManager.validatePacket(healthReport(), reporterPeerID))
        assertArrayEquals(signingKey, encryption.lastVerifyKey)
    }

    @Test
    fun `announce older than the health report retention teaches nothing`() {
        securityManager.validatePacket(
            announce(ageMs = AppConstants.Sync.HEALTH_REPORT_RETENTION_MS + AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 1),
            reporterPeerID
        )

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    @Test
    fun `future-dated announce beyond the clock skew teaches nothing`() {
        securityManager.validatePacket(announce(ageMs = -(AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS + 60_000)), reporterPeerID)

        assertFalse(securityManager.validatePacket(healthReport(), reporterPeerID))
    }

    private fun announce(
        ageMs: Long,
        noisePublicKey: ByteArray = noiseKey,
        signingPublicKey: ByteArray = signingKey,
        signature: ByteArray = validSignature,
        ttl: UByte = AppConstants.SYNC_TTL_HOPS
    ) = BitchatPacket(
        version = 1u,
        type = MessageType.ANNOUNCE.value,
        senderID = reporterPeerID.hexToBytes(),
        recipientID = null,
        timestamp = (now - ageMs).toULong(),
        payload = IdentityAnnouncement("Reporter", noisePublicKey, signingPublicKey).encode()!!,
        signature = signature,
        ttl = ttl
    )

    private fun healthReport(signature: ByteArray = validSignature) = signed(MessageType.HEALTH_REPORT, signature)

    private fun signed(type: MessageType, signature: ByteArray = validSignature) = BitchatPacket(
        version = 1u,
        type = type.value,
        senderID = reporterPeerID.hexToBytes(),
        recipientID = null,
        timestamp = (now - 30_000).toULong(),
        payload = byteArrayOf(0x30, 0x01, type.value.toByte()),
        signature = signature,
        ttl = 0u
    )

    private fun livePeer(signingPublicKey: ByteArray) = PeerInfo(
        id = reporterPeerID,
        nickname = "Reporter",
        isConnected = true,
        isDirectConnection = false,
        noisePublicKey = noiseKey,
        signingPublicKey = signingPublicKey,
        isVerifiedNickname = true,
        lastSeen = now
    )

    private fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
