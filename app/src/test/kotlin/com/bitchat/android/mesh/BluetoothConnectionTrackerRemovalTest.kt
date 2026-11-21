package com.bitchat.android.mesh

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import com.bitchat.android.testsupport.RecordingExperimentRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever

/** P0-1：藍牙關閉時清空連線表，以及本機拆掉單一鏈路。 */
class BluetoothConnectionTrackerRemovalTest {
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private val recorder = RecordingExperimentRecorder()
    private val tracker = BluetoothConnectionTracker(scope, mock(), recorder)

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun device(address: String): BluetoothDevice = mock<BluetoothDevice>().also {
        whenever(it.address).thenReturn(address)
    }

    @Test
    fun `stopping removes every link, reports each identified one down and returns them for the caller`() {
        val gatt = mock<BluetoothGatt>()
        tracker.addDeviceConnection(
            CLIENT_ADDRESS,
            BluetoothConnectionTracker.DeviceConnection(
                device = device(CLIENT_ADDRESS),
                gatt = gatt,
                isClient = true,
                peerID = PEER_A,
                linkID = "client-link"
            )
        )
        tracker.addDeviceConnection(
            SERVER_ADDRESS,
            BluetoothConnectionTracker.DeviceConnection(
                device = device(SERVER_ADDRESS),
                isClient = false,
                linkID = "server-link"
            )
        )
        tracker.observePeerIfCurrent(CLIENT_ADDRESS, "client-link", PEER_A)
        tracker.observePeerIfCurrent(SERVER_ADDRESS, "server-link", PEER_B)
        recorder.events.clear()

        val removed = tracker.stopAndRemoveAll().associateBy { it.connection.linkID }

        assertEquals(setOf("client-link", "server-link"), removed.keys)
        assertEquals(PEER_A, removed.getValue("client-link").observedPeerID)
        assertEquals(PEER_B, removed.getValue("server-link").observedPeerID)
        assertEquals(
            setOf("LINK_DOWN:$CLIENT_ADDRESS:$PEER_A", "LINK_DOWN:$SERVER_ADDRESS:$PEER_B"),
            recorder.events.toSet()
        )
        assertEquals(0, tracker.getConnectedDeviceCount())
        assertTrue(tracker.addressPeerMap.isEmpty())
        verify(gatt).disconnect()
        verify(gatt).close()
    }

    @Test
    fun `after bluetooth goes off a stale entry no longer makes the peer look connected`() {
        // 試跑中 D：連線表留著 A 的舊連線，掃描到 A（-67 dBm）也因 isPeerConnected 而跳過。
        tracker.addDeviceConnection(
            CLIENT_ADDRESS,
            BluetoothConnectionTracker.DeviceConnection(
                device = device(CLIENT_ADDRESS),
                isClient = true,
                peerID = PEER_A,
                linkID = "client-link"
            )
        )
        assertTrue(tracker.isPeerConnected(PEER_A))

        tracker.stopAndRemoveAll()

        assertFalse(tracker.isPeerConnected(PEER_A))
        assertFalse(tracker.isDeviceConnected(CLIENT_ADDRESS))
    }

    @Test
    fun `removing the current link returns its observed peer`() {
        val dev = device(CLIENT_ADDRESS)
        tracker.addDeviceConnection(
            CLIENT_ADDRESS,
            BluetoothConnectionTracker.DeviceConnection(device = dev, isClient = true, linkID = "link-a")
        )
        tracker.observePeerIfCurrent(CLIENT_ADDRESS, "link-a", PEER_A)

        val removed = tracker.removeConnectionIfCurrent(CLIENT_ADDRESS, "link-a")

        assertEquals(PEER_A, removed?.observedPeerID)
        assertSame(dev, removed?.connection?.device)
        assertFalse(tracker.isDeviceConnected(CLIENT_ADDRESS))
    }

    @Test
    fun `a late removal for a replaced link leaves the replacement and its peer alone`() {
        val dev = device(CLIENT_ADDRESS)
        tracker.addDeviceConnection(
            CLIENT_ADDRESS,
            BluetoothConnectionTracker.DeviceConnection(device = dev, isClient = true, linkID = "link-a")
        )
        tracker.addDeviceConnection(
            CLIENT_ADDRESS,
            BluetoothConnectionTracker.DeviceConnection(device = dev, isClient = true, linkID = "link-b")
        )
        tracker.observePeerIfCurrent(CLIENT_ADDRESS, "link-b", PEER_A)

        assertNull(tracker.removeConnectionIfCurrent(CLIENT_ADDRESS, "link-a"))
        assertEquals("link-b", tracker.getCurrentLinkID(CLIENT_ADDRESS))
        assertEquals(PEER_A, tracker.addressPeerMap[CLIENT_ADDRESS])
    }

    private companion object {
        const val CLIENT_ADDRESS = "AA:BB:CC:DD:EE:01"
        const val SERVER_ADDRESS = "AA:BB:CC:DD:EE:02"
        const val PEER_A = "0011223344556677"
        const val PEER_B = "8899aabbccddeeff"
    }
}
