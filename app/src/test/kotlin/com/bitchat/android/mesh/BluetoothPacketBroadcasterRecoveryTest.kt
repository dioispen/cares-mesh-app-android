package com.bitchat.android.mesh

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.os.Build
import android.os.DeadObjectException
import android.os.DeadSystemException
import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * P0-1：寫入沒被藍牙堆疊接受時不再無限重試。試跑中 D 對失效的 GATT 物件每 15 ms 重試一次，
 * 藍牙重新開啟後記了約 13.3 萬次 `DeadObjectException`。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class BluetoothPacketBroadcasterRecoveryTest {
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val tracker = BluetoothConnectionTracker(scope, mock())
    private val clock = AtomicLong(0L)
    private val faults: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val stalled: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val writes = AtomicInteger()
    private var adapterOn = true
    private val broadcaster = BluetoothPacketBroadcaster(
        connectionScope = scope,
        connectionTracker = tracker,
        fragmentManager = null,
        myPeerID = MY_PEER_ID,
        isAdapterOn = { adapterOn },
        onLinkStalled = { address, linkID -> stalled += "$address/$linkID" },
        onBluetoothFault = { reason -> faults += reason },
        clockMs = { clock.get() }
    )

    @After
    fun tearDown() {
        broadcaster.shutdown()
        scope.cancel()
    }

    private fun connectClientLink(onWrite: (call: Int) -> Boolean) {
        val device = mock<BluetoothDevice>()
        whenever(device.address).thenReturn(ADDRESS)
        val gatt = mock<BluetoothGatt>()
        whenever(gatt.writeCharacteristic(any<BluetoothGattCharacteristic>())).thenAnswer {
            onWrite(writes.incrementAndGet())
        }
        tracker.addDeviceConnection(
            ADDRESS,
            BluetoothConnectionTracker.DeviceConnection(
                device = device,
                gatt = gatt,
                characteristic = mock<BluetoothGattCharacteristic>(),
                isClient = true,
                linkID = LINK_ID
            )
        )
    }

    private fun send(timestamp: Long = 1L): Boolean {
        val packet = BitchatPacket(
            version = 1u,
            type = MessageType.MESSAGE.value,
            senderID = MeshPacketUtils.hexStringToByteArray(MY_PEER_ID),
            recipientID = null,
            timestamp = timestamp.toULong(),
            payload = byteArrayOf(1, 2, 3),
            ttl = 7u
        )
        return broadcaster.sendPacketToLink(RoutedPacket(packet), ADDRESS, LINK_ID, null, null)
    }

    private fun waitUntil(timeoutMs: Long = 3_000L, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(5)
        assertTrue("condition not met within ${timeoutMs}ms", condition())
    }

    @Test
    fun `a dead binder is reported once as a bluetooth fault and the write is not retried`() {
        connectClientLink { throw RuntimeException(DeadObjectException()) }

        assertTrue(send())
        waitUntil { faults.size == 1 }
        Thread.sleep(150) // 舊行為：這段時間會重試約 10 次

        assertEquals(1, writes.get())
        assertEquals(1, faults.size)
        assertTrue(stalled.isEmpty())
    }

    @Test
    fun `a write refused while the adapter is off is reported as a bluetooth fault`() {
        adapterOn = false
        connectClientLink { false }

        assertTrue(send())
        waitUntil { faults.size == 1 }
        Thread.sleep(150)

        assertEquals(1, writes.get())
    }

    @Test
    fun `a busy link is retried, then dropped once it accepts nothing for the stall timeout`() {
        connectClientLink { false }

        assertTrue(send())
        waitUntil { writes.get() >= LinkSendFailurePolicy.MIN_FAILURES_BEFORE_DROP }
        assertTrue(stalled.isEmpty())

        clock.set(LinkSendFailurePolicy.STALL_TIMEOUT_MS)
        waitUntil { stalled.size == 1 }
        val writesAtDrop = writes.get()
        Thread.sleep(150)

        assertEquals("$ADDRESS/$LINK_ID", stalled.single())
        assertEquals(writesAtDrop, writes.get())
        assertTrue(faults.isEmpty())
    }

    @Test
    fun `an accepted write restarts the failure streak`() {
        connectClientLink { call ->
            when (call) {
                1 -> false
                2 -> true
                else -> {
                    // 第一次失敗後已過了很久；連續失敗要從這裡重新算
                    clock.set(LinkSendFailurePolicy.STALL_TIMEOUT_MS * 2)
                    false
                }
            }
        }

        assertTrue(send(timestamp = 1L))
        assertTrue(send(timestamp = 2L))
        waitUntil { writes.get() == 2 }
        broadcaster.onGattClientWriteComplete(ADDRESS, LINK_ID, BluetoothGatt.GATT_SUCCESS)
        waitUntil { writes.get() >= LinkSendFailurePolicy.MIN_FAILURES_BEFORE_DROP + 5 }

        assertTrue(stalled.isEmpty())
        assertTrue(faults.isEmpty())
    }

    @Test
    fun `dead binders are recognised through wrapping runtime exceptions`() {
        assertTrue(LinkSendFailurePolicy.isDeadBinder(DeadObjectException()))
        // Android 13 起 rethrowFromSystemServer() 的形式
        assertTrue(LinkSendFailurePolicy.isDeadBinder(RuntimeException(DeadSystemException())))
        assertTrue(LinkSendFailurePolicy.isDeadBinder(RuntimeException(DeadObjectException())))
        assertFalse(LinkSendFailurePolicy.isDeadBinder(IllegalStateException("busy")))
        assertFalse(LinkSendFailurePolicy.isDeadBinder(null))
    }

    private companion object {
        const val MY_PEER_ID = "0011223344556677"
        const val ADDRESS = "AA:BB:CC:DD:EE:01"
        const val LINK_ID = "link-a"
    }
}
