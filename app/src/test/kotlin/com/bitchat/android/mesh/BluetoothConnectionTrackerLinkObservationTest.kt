package com.bitchat.android.mesh

import android.bluetooth.BluetoothDevice
import com.bitchat.android.experiment.ExperimentRecorder
import com.bitchat.android.testsupport.RecordingExperimentRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever
import kotlin.concurrent.thread

class BluetoothConnectionTrackerLinkObservationTest {
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private val tracker = BluetoothConnectionTracker(scope, mock())

    @After
    fun tearDown() {
        scope.cancel()
    }

    @Test
    fun `stale connection callbacks cannot mutate or remove replacement link`() {
        val address = "AA:BB:CC:DD:EE:FF"
        val device = mock<BluetoothDevice>()
        whenever(device.address).thenReturn(address)

        tracker.addDeviceConnection(
            address,
            BluetoothConnectionTracker.DeviceConnection(device = device, linkID = "link-a")
        )
        tracker.addDeviceConnection(
            address,
            BluetoothConnectionTracker.DeviceConnection(device = device, linkID = "link-b")
        )

        assertFalse(
            tracker.updateDeviceConnectionIfCurrent(address, "link-a") {
                it.copy(rssi = -10)
            }
        )
        assertFalse(tracker.cleanupDeviceConnectionIfCurrent(address, "link-a"))
        assertEquals("link-b", tracker.getCurrentLinkID(address))

        assertTrue(tracker.observePeerIfCurrent(address, "link-b", "0011223344556677"))
        assertEquals("0011223344556677", tracker.addressPeerMap[address])
        assertSame(device, tracker.getDeviceConnection(address)?.device)
    }

    @Test
    fun `one peer can remain directly observed over multiple current links`() {
        val firstAddress = "AA:BB:CC:DD:EE:01"
        val secondAddress = "AA:BB:CC:DD:EE:02"
        val firstDevice = mock<BluetoothDevice>()
        val secondDevice = mock<BluetoothDevice>()
        whenever(firstDevice.address).thenReturn(firstAddress)
        whenever(secondDevice.address).thenReturn(secondAddress)

        tracker.addDeviceConnection(
            firstAddress,
            BluetoothConnectionTracker.DeviceConnection(device = firstDevice, linkID = "link-a")
        )
        tracker.addDeviceConnection(
            secondAddress,
            BluetoothConnectionTracker.DeviceConnection(device = secondDevice, linkID = "link-b")
        )

        assertTrue(tracker.observePeerIfCurrent(firstAddress, "link-a", PEER_ID))
        assertTrue(tracker.observePeerIfCurrent(secondAddress, "link-b", PEER_ID))
        assertTrue(tracker.observePeerIfCurrent(secondAddress, "link-b", PEER_ID))
        assertEquals(2, tracker.addressPeerMap.values.count { it == PEER_ID })

        assertTrue(tracker.cleanupDeviceConnectionIfCurrent(firstAddress, "link-a"))
        assertEquals(PEER_ID, tracker.addressPeerMap[secondAddress])
        assertTrue(tracker.addressPeerMap.containsValue(PEER_ID))
    }

    // Experiment recorder insertion points (#70).

    private fun recordingTracker(): Pair<BluetoothConnectionTracker, RecordingExperimentRecorder> {
        val recorder = RecordingExperimentRecorder()
        return BluetoothConnectionTracker(scope, mock(), recorder) to recorder
    }

    private fun BluetoothConnectionTracker.connect(address: String, linkID: String) {
        val device = mock<BluetoothDevice>()
        whenever(device.address).thenReturn(address)
        addDeviceConnection(address, BluetoothConnectionTracker.DeviceConnection(device = device, linkID = linkID))
    }

    @Test
    fun `a link is up once its peer is first observed, and repeated announces do not repeat it`() {
        val (tracker, recorder) = recordingTracker()
        tracker.connect(ADDRESS, "link-a")
        assertEquals(emptyList<String>(), recorder.events)

        tracker.observePeerIfCurrent(ADDRESS, "link-a", PEER_ID)
        tracker.observePeerIfCurrent(ADDRESS, "link-a", PEER_ID)

        assertEquals(listOf("LINK_UP:$ADDRESS:$PEER_ID"), recorder.events)
    }

    @Test
    fun `an identified link going away is down, an unidentified one records nothing`() {
        val (tracker, recorder) = recordingTracker()
        tracker.connect(ADDRESS, "link-a")
        tracker.connect(OTHER_ADDRESS, "link-b")
        tracker.observePeerIfCurrent(ADDRESS, "link-a", PEER_ID)

        tracker.cleanupDeviceConnectionIfCurrent(ADDRESS, "link-a")
        tracker.cleanupDeviceConnection(OTHER_ADDRESS)

        assertEquals(listOf("LINK_UP:$ADDRESS:$PEER_ID", "LINK_DOWN:$ADDRESS:$PEER_ID"), recorder.events)
    }

    @Test
    fun `a replacement connection on the same address ends the old identified link`() {
        val (tracker, recorder) = recordingTracker()
        tracker.connect(ADDRESS, "link-a")
        tracker.observePeerIfCurrent(ADDRESS, "link-a", PEER_ID)

        tracker.connect(ADDRESS, "link-b")

        assertEquals(listOf("LINK_UP:$ADDRESS:$PEER_ID", "LINK_DOWN:$ADDRESS:$PEER_ID"), recorder.events)
    }

    @Test
    fun `stopping the tracker ends every identified link`() {
        val (tracker, recorder) = recordingTracker()
        tracker.connect(ADDRESS, "link-a")
        tracker.observePeerIfCurrent(ADDRESS, "link-a", PEER_ID)

        tracker.stop()

        assertEquals(listOf("LINK_UP:$ADDRESS:$PEER_ID", "LINK_DOWN:$ADDRESS:$PEER_ID"), recorder.events)
    }

    @Test
    fun `a link cleaned up while its LINK_UP is being recorded goes down after it, not before`() {
        val events = java.util.Collections.synchronizedList(mutableListOf<String>())
        lateinit var tracker: BluetoothConnectionTracker
        val recorder = object : ExperimentRecorder by ExperimentRecorder.NoOp {
            override fun onLinkUp(deviceAddress: String, peerID: String) {
                // A GATT disconnect arriving right after the peer was observed.
                val disconnect = thread { tracker.cleanupDeviceConnectionIfCurrent(deviceAddress, "link-a") }
                disconnect.join(200)
                events += "LINK_UP"
            }

            override fun onLinkDown(deviceAddress: String, peerID: String) {
                events += "LINK_DOWN"
            }
        }
        tracker = BluetoothConnectionTracker(scope, mock(), recorder)
        tracker.connect(ADDRESS, "link-a")

        tracker.observePeerIfCurrent(ADDRESS, "link-a", PEER_ID)
        repeat(50) { if (events.size < 2) Thread.sleep(10) }

        assertEquals(listOf("LINK_UP", "LINK_DOWN"), events.toList())
    }

    private companion object {
        const val PEER_ID = "0011223344556677"
        const val ADDRESS = "AA:BB:CC:DD:EE:10"
        const val OTHER_ADDRESS = "AA:BB:CC:DD:EE:11"
    }
}
