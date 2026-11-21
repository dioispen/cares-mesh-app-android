package com.bitchat.android.mesh

import android.bluetooth.BluetoothDevice
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/**
 * P0-2 殭屍連線偵測（2026-11-18 四機試跑 12.1）：C 掛著 2–3 條連線 20 分鐘，一筆都沒收到，
 * `STAT` 仍列出 A、B、D。
 */
class BluetoothConnectionTrackerIdleLinkTest {
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private var now = 0L
    private val tracker = BluetoothConnectionTracker(scope, mock(), monotonicClockMs = { now })

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun connect(address: String, linkID: String) {
        val device = mock<BluetoothDevice>()
        whenever(device.address).thenReturn(address)
        tracker.addDeviceConnection(
            address,
            BluetoothConnectionTracker.DeviceConnection(device = device, linkID = linkID)
        )
    }

    private fun idleLinkIDs(): List<String> = tracker.findIdleLinks().map { it.linkID }

    @Test
    fun `a link that never receives anything is idle only after the timeout since it connected`() {
        now = 1_000L
        connect(ADDRESS, "link-a")

        now = 1_000L + TIMEOUT
        assertEquals(emptyList<String>(), idleLinkIDs())

        now = 1_000L + TIMEOUT + 1
        val idle = tracker.findIdleLinks().single()
        assertEquals(ADDRESS, idle.deviceAddress)
        assertEquals("link-a", idle.linkID)
        assertEquals(TIMEOUT + 1, idle.idleForMs)
    }

    @Test
    fun `every received packet pushes the deadline back`() {
        connect(ADDRESS, "link-a")
        now = 60_000L
        tracker.noteLinkReceive("link-a")

        now = 60_000L + TIMEOUT
        assertEquals(emptyList<String>(), idleLinkIDs())
        now = 60_000L + TIMEOUT + 1
        assertEquals(listOf("link-a"), idleLinkIDs())
    }

    @Test
    fun `only the quiet link is reported when another link keeps receiving`() {
        connect(ADDRESS, "link-a")
        connect(OTHER_ADDRESS, "link-b")
        // 鄰居每 30 s 在每條鏈路送一次 REQUEST_SYNC；只有 link-b 收得到
        for (t in 30_000L..300_000L step 30_000L) {
            now = t
            tracker.noteLinkReceive("link-b")
        }

        assertEquals(listOf("link-a"), idleLinkIDs())
    }

    @Test
    fun `a late packet from a replaced GATT generation does not keep the new link alive`() {
        connect(ADDRESS, "link-a")
        now = 50_000L
        connect(ADDRESS, "link-b") // 同一個位址，新的 GATT 連線

        now = 100_000L
        tracker.noteLinkReceive("link-a") // 舊連線晚到的封包

        now = 50_000L + TIMEOUT + 1
        assertEquals(listOf("link-b"), idleLinkIDs())
    }

    @Test
    fun `a removed link is not reported, and a late packet does not bring it back`() {
        connect(ADDRESS, "link-a")
        assertTrue(tracker.cleanupDeviceConnectionIfCurrent(ADDRESS, "link-a"))
        now = 1_000L
        tracker.noteLinkReceive("link-a")

        now = 10 * TIMEOUT
        assertEquals(emptyList<String>(), idleLinkIDs())
        assertFalse(tracker.isDeviceConnected(ADDRESS))

        // 同一位址重新連上，從新的連上時間起算
        connect(ADDRESS, "link-b")
        now += TIMEOUT
        assertEquals(emptyList<String>(), idleLinkIDs())
    }

    @Test
    fun `links cleared when bluetooth goes off leave nothing to report`() {
        connect(ADDRESS, "link-a")
        connect(OTHER_ADDRESS, "link-b")
        tracker.stopAndRemoveAll()

        now = 10 * TIMEOUT
        assertEquals(emptyList<String>(), idleLinkIDs())
    }

    @Test
    fun `idle means strictly longer than the timeout`() {
        assertFalse(LinkIdlePolicy.isIdle(lastActivityMs = 5_000L, nowMs = 5_000L + TIMEOUT))
        assertTrue(LinkIdlePolicy.isIdle(lastActivityMs = 5_000L, nowMs = 5_000L + TIMEOUT + 1))
    }

    @Test
    fun `the timeout leaves room for a neighbour whose sync heartbeat is stretched by sleep`() {
        // 鄰居每 30 s 送 REQUEST_SYNC，休眠時拉長到約 60 s；門檻要大於它
        assertTrue(TIMEOUT > 60_000L)
    }

    private companion object {
        val TIMEOUT = AppConstants.Mesh.LINK_IDLE_TIMEOUT_MS
        const val ADDRESS = "AA:BB:CC:DD:EE:01"
        const val OTHER_ADDRESS = "AA:BB:CC:DD:EE:02"
    }
}
