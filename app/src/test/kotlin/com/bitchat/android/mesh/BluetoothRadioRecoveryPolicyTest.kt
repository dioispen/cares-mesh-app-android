package com.bitchat.android.mesh

import com.bitchat.android.mesh.BluetoothRadioPolicy.Action.NONE
import com.bitchat.android.mesh.BluetoothRadioPolicy.Action.START
import com.bitchat.android.mesh.BluetoothRadioPolicy.Action.STOP
import com.bitchat.android.mesh.LinkSendFailurePolicy.Action.DROP_LINK
import com.bitchat.android.mesh.LinkSendFailurePolicy.Action.RESTART_BLUETOOTH
import com.bitchat.android.mesh.LinkSendFailurePolicy.Action.RETRY
import org.junit.Assert.assertEquals
import org.junit.Test

/** P0-1（2026-11-18 四機試跑 7.2、12.2）：藍牙關閉／重新開啟與 GATT 失效時的判斷。 */
class BluetoothRadioRecoveryPolicyTest {

    private fun radio(
        running: Boolean,
        requested: Boolean = true,
        transportEnabled: Boolean = true,
        adapterOn: Boolean,
        faulted: Boolean = false
    ) = BluetoothRadioPolicy.decide(running, requested, transportEnabled, adapterOn, faulted)

    @Test
    fun `turning bluetooth off while the mesh runs tears the components down once`() {
        assertEquals(STOP, radio(running = true, adapterOn = false))
        // TURNING_OFF 已經拆掉，接著的 OFF 不再動作
        assertEquals(NONE, radio(running = false, adapterOn = false))
    }

    @Test
    fun `turning bluetooth back on rebuilds the components`() {
        assertEquals(START, radio(running = false, adapterOn = true))
        assertEquals(NONE, radio(running = true, adapterOn = true))
    }

    @Test
    fun `a mesh started while bluetooth is off waits, then starts when it turns on`() {
        assertEquals(NONE, radio(running = false, requested = true, adapterOn = false))
        assertEquals(START, radio(running = false, requested = true, adapterOn = true))
    }

    @Test
    fun `bluetooth turning on does not re-enable a transport the debug toggle disabled`() {
        // disableTransport() 清掉 requested
        assertEquals(NONE, radio(running = false, requested = false, adapterOn = true))
        // BLE 總開關關著
        assertEquals(NONE, radio(running = false, transportEnabled = false, adapterOn = true))
    }

    @Test
    fun `disabling the transport while running tears the components down`() {
        assertEquals(STOP, radio(running = true, requested = false, adapterOn = true))
        assertEquals(STOP, radio(running = true, transportEnabled = false, adapterOn = true))
    }

    @Test
    fun `a dead binder tears the running components down even though the adapter reports on`() {
        assertEquals(STOP, radio(running = true, adapterOn = true, faulted = true))
        // 下一次判斷（不再是失效回報）重建
        assertEquals(START, radio(running = false, adapterOn = true))
    }

    private fun send(
        binderDead: Boolean = false,
        adapterOn: Boolean = true,
        failures: Int = 1,
        failingForMs: Long = 0L
    ) = LinkSendFailurePolicy.decide(binderDead, adapterOn, failures, failingForMs)

    @Test
    fun `a busy link is retried`() {
        assertEquals(RETRY, send(failures = 1, failingForMs = 0L))
        assertEquals(RETRY, send(failures = 500, failingForMs = LinkSendFailurePolicy.STALL_TIMEOUT_MS - 1))
    }

    @Test
    fun `a dead binder restarts bluetooth on the first failure`() {
        assertEquals(RESTART_BLUETOOTH, send(binderDead = true, failures = 1))
    }

    @Test
    fun `a write refused while the adapter is not on restarts bluetooth on the first failure`() {
        // 舊版 API 吞掉 DeadObjectException、只回傳 false
        assertEquals(RESTART_BLUETOOTH, send(adapterOn = false, failures = 1))
    }

    @Test
    fun `a link that accepts nothing for the stall timeout is dropped`() {
        assertEquals(
            DROP_LINK,
            send(
                failures = LinkSendFailurePolicy.MIN_FAILURES_BEFORE_DROP,
                failingForMs = LinkSendFailurePolicy.STALL_TIMEOUT_MS
            )
        )
    }

    @Test
    fun `a few failures spread over a long time are not a stalled link`() {
        assertEquals(
            RETRY,
            send(
                failures = LinkSendFailurePolicy.MIN_FAILURES_BEFORE_DROP - 1,
                failingForMs = LinkSendFailurePolicy.STALL_TIMEOUT_MS * 10
            )
        )
    }
}
