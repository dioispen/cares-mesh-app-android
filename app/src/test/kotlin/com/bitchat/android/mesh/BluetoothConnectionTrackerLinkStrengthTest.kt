package com.bitchat.android.mesh

import android.bluetooth.BluetoothDevice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/** Which link is the weakest, how fresh its RSSI is, and how many peers the links reach (P1-5). */
class BluetoothConnectionTrackerLinkStrengthTest {
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private val tracker = BluetoothConnectionTracker(scope, mock())

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun link(
        address: String,
        rssi: Int = Int.MIN_VALUE,
        isClient: Boolean = true,
        connectedAt: Long = 1_000L,
        peerID: String? = null
    ): BluetoothConnectionTracker.DeviceConnection {
        val device = mock<BluetoothDevice>()
        whenever(device.address).thenReturn(address)
        val connection = BluetoothConnectionTracker.DeviceConnection(
            device = device,
            rssi = rssi,
            isClient = isClient,
            connectedAt = connectedAt,
            peerID = peerID,
            linkID = "link-$address"
        )
        tracker.addDeviceConnection(address, connection)
        return connection
    }

    private fun evicted(maxOverall: Int, maxServer: Int = 8, maxClient: Int = 8) =
        tracker.getConnectionsToEvict(maxOverall, maxServer, maxClient).map { it.device.address }.toSet()

    @Test
    fun `over the overall limit the weakest link goes, not the oldest`() {
        link("A", rssi = -60, connectedAt = 1_000)
        link("B", rssi = -92, connectedAt = 3_000)
        link("C", rssi = -75, connectedAt = 2_000)

        assertEquals(setOf("B"), evicted(maxOverall = 2))
    }

    @Test
    fun `equally weak links go oldest first`() {
        link("A", rssi = -80, connectedAt = 2_000)
        link("B", rssi = -80, connectedAt = 1_000)
        link("C", rssi = -60, connectedAt = 500)

        assertEquals(setOf("B"), evicted(maxOverall = 2))
    }

    @Test
    fun `links of unknown strength go after known ones, oldest first`() {
        link("unknown-old", connectedAt = 1_000)
        link("unknown-new", connectedAt = 2_000)
        link("known", rssi = -50, connectedAt = 3_000)

        assertEquals(setOf("known"), evicted(maxOverall = 2))
        assertEquals(setOf("known", "unknown-old"), evicted(maxOverall = 1))
    }

    @Test
    fun `the overall limit still prefers evicting clients`() {
        link("server", rssi = -99, isClient = false)
        link("client", rssi = -60, isClient = true)

        assertEquals(setOf("client"), evicted(maxOverall = 1))
    }

    @Test
    fun `role limits evict the weakest excess within the role`() {
        link("c1", rssi = -70, isClient = true, connectedAt = 1_000)
        link("c2", rssi = -90, isClient = true, connectedAt = 2_000)
        link("s1", rssi = -95, isClient = false, connectedAt = 1_500)
        link("s2", rssi = -65, isClient = false, connectedAt = 500)

        assertEquals(setOf("c2", "s1"), evicted(maxOverall = 8, maxServer = 1, maxClient = 1))
    }

    @Test
    fun `a connected peer's later scans replace its connect-time RSSI`() {
        link("A", rssi = -60, connectedAt = 1_000) // strong when it connected, long ago
        link("B", rssi = -80, connectedAt = 1_000)

        tracker.updateScanRSSI("A", -97, peerID = null)

        assertEquals(-97, tracker.getBestRSSI("A"))
        assertEquals(setOf("A"), evicted(maxOverall = 1))
    }

    @Test
    fun `an inbound link takes the RSSI its peer advertises with under another address`() {
        link("inbound", isClient = false)
        assertTrue(tracker.observePeerIfCurrent("inbound", "link-inbound", PEER))
        assertNull(tracker.getBestRSSI("inbound"))

        tracker.updateScanRSSI("advertising-address", -88, PEER)

        assertEquals(-88, tracker.getBestRSSI("inbound"))
    }

    @Test
    fun `the weakest client link is reported with its fresh RSSI`() {
        link("c1", rssi = -70)
        link("c2", rssi = -65)
        link("s1", rssi = -99, isClient = false)
        tracker.updateScanRSSI("c2", -93)

        val (weakest, rssi) = tracker.getWeakestClientLink()!!

        assertEquals("c2", weakest.device.address)
        assertEquals(-93, rssi)
    }

    @Test
    fun `without client links there is no weakest client link`() {
        link("s1", rssi = -99, isClient = false)

        assertNull(tracker.getWeakestClientLink())
    }

    @Test
    fun `direct peers are counted per peer, not per link, once identified`() {
        link("client-to-P", peerID = PEER) // identified by the scan's service data
        link("server-from-P", isClient = false) // the same peer's link in the other role
        link("server-unidentified", isClient = false)
        assertEquals(1, tracker.getDirectPeerCount())

        tracker.observePeerIfCurrent("server-from-P", "link-server-from-P", PEER)
        assertEquals(1, tracker.getDirectPeerCount())

        tracker.observePeerIfCurrent("server-unidentified", "link-server-unidentified", OTHER_PEER)
        assertEquals(2, tracker.getDirectPeerCount())
    }

    @Test
    fun `a peer linked only inbound counts as directly connected`() {
        link("server-from-P", isClient = false)
        assertFalse(tracker.isPeerDirectlyConnected(PEER))

        tracker.observePeerIfCurrent("server-from-P", "link-server-from-P", PEER)

        assertTrue(tracker.isPeerDirectlyConnected(PEER))
        assertFalse("isPeerConnected still only sees scan-identified links", tracker.isPeerConnected(PEER))
    }

    private companion object {
        const val PEER = "0011223344556677"
        const val OTHER_PEER = "8899aabbccddeeff"
    }
}
