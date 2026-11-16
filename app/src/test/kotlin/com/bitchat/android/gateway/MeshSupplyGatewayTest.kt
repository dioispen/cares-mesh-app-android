package com.bitchat.android.gateway

import android.os.Build
import com.bitchat.android.protocol.SupplyExchangeAction
import com.bitchat.android.protocol.SupplyExchangePacket
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 物資 Gateway：只看對外行為——給定收到的封包、網路與登入狀態、時間流逝，觀察對上傳 port 的呼叫。
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class MeshSupplyGatewayTest {

    private var now = 1_800_000_000_000L
    private val uploader = FakeUploader()

    @Test
    fun `a fresh packet is uploaded at once while signed in and online`() = runTest {
        val gateway = gateway()
        val packet = heard()

        gateway.onPacket(packet)
        runCurrent()

        assertEquals(listOf(packet to GATEWAY_UID), uploader.uploads)
    }

    @Test
    fun `nothing is uploaded while signed out or switched off`() = runTest {
        val signedOut = gateway(uid = null)
        signedOut.onPacket(heard())
        runCurrent()
        assertTrue(uploader.uploads.isEmpty())

        val off = gateway()
        off.onEnabledChanged(false)
        off.onPacket(heard())
        runCurrent()
        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `the same packet id is uploaded only once`() = runTest {
        val gateway = gateway()

        gateway.onPacket(heard())
        gateway.onPacket(heard())
        runCurrent()

        assertEquals(1, uploader.uploads.size)
    }

    @Test
    fun `a refused write counts as already uploaded`() = runTest {
        val gateway = gateway()
        uploader.results += UploadResult.PERMISSION_DENIED

        gateway.onPacket(heard())
        gateway.onPacket(heard())
        runCurrent()

        assertEquals(1, uploader.uploads.size)
    }

    @Test
    fun `packets heard offline are uploaded when the network comes back`() = runTest {
        val gateway = gateway(online = false)
        val a = heard(packetId = "a".repeat(32))
        val b = heard(packetId = "b".repeat(32))

        gateway.onPacket(a)
        gateway.onPacket(b)
        runCurrent()
        assertTrue(uploader.uploads.isEmpty())

        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(listOf(a to GATEWAY_UID, b to GATEWAY_UID), uploader.uploads)
    }

    @Test
    fun `a transient failure keeps the packet for the next network event`() = runTest {
        val gateway = gateway()
        uploader.results += UploadResult.TRANSIENT_FAILURE
        val packet = heard()

        gateway.onPacket(packet)
        runCurrent()
        assertEquals(1, uploader.uploads.size)

        gateway.onNetworkChanged(false)
        gateway.onNetworkChanged(true)
        runCurrent()

        assertEquals(listOf(packet to GATEWAY_UID, packet to GATEWAY_UID), uploader.uploads)
    }

    @Test
    fun `packets older than the retention are dropped`() = runTest {
        val gateway = gateway()

        gateway.onPacket(heard(createdAtMs = now - TWO_HOURS_MS - 1))
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    @Test
    fun `held packets are not charged to another account`() = runTest {
        val gateway = gateway(online = false)
        gateway.onPacket(heard())
        runCurrent()

        gateway.onSignedIn(null)
        gateway.onSignedIn("uid-someone-else")
        gateway.onNetworkChanged(true)
        runCurrent()

        assertTrue(uploader.uploads.isEmpty())
    }

    private fun TestScope.gateway(uid: String? = GATEWAY_UID, online: Boolean = true): MeshSupplyGateway =
        MeshSupplyGateway(uploader, nowMs = { now }, scope = backgroundScope).also {
            it.onSignedIn(uid)
            it.onNetworkChanged(online)
            runCurrent()
        }

    private fun heard(
        packetId: String = "0123456789abcdef0123456789abcdef",
        createdAtMs: Long = now - 60_000
    ) = GatewaySupplyPacket(
        supply = SupplyExchangePacket(
            action = SupplyExchangeAction.REQUEST,
            exchangeId = "fedcba9876543210fedcba9876543210",
            itemId = "water",
            itemName = "礦泉水",
            quantity = 12,
            unit = "瓶"
        ),
        senderPeerID = "0102030405060708",
        packetId = packetId,
        rawPacket = byteArrayOf(0x01, 0x31),
        createdAtMs = createdAtMs
    )

    private class FakeUploader : MeshSupplyUploader {
        val uploads = mutableListOf<Pair<GatewaySupplyPacket, String>>()
        val results = ArrayDeque<UploadResult>()

        override suspend fun upload(packet: GatewaySupplyPacket, gatewayUid: String): UploadResult {
            uploads += packet to gatewayUid
            return results.removeFirstOrNull() ?: UploadResult.UPLOADED
        }
    }

    private companion object {
        const val GATEWAY_UID = "uid-gateway"
        const val TWO_HOURS_MS = 2 * 60 * 60 * 1000L
    }
}
