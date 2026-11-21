package com.bitchat.android.sync

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.bitchat.android.identity.SecureIdentityStateManager
import com.bitchat.android.service.HealthReportBroadcast
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.UUID

/** P0-3 的保存位置：身分的加密 preferences，panic 清除身分時一併清掉。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class EncryptedOwnHealthReportStoreTest {

    private lateinit var prefs: SharedPreferences

    @Before
    fun setup() {
        prefs = RuntimeEnvironment.getApplication().getSharedPreferences(
            "own-health-report-${UUID.randomUUID()}",
            Context.MODE_PRIVATE
        )
    }

    /** What a restart gets: new instances over the same preferences file. */
    private fun identity() = SecureIdentityStateManager(prefs, testOnly = true)
    private fun store(identity: SecureIdentityStateManager = identity()) = EncryptedOwnHealthReportStore { identity }

    @Test
    fun `what was written is read back after a restart`() {
        val encoded = byteArrayOf(1, 0x30, 3, 0, -1, 127, 64)

        store().write(encoded)

        assertArrayEquals(encoded, store().read())
    }

    @Test
    fun `clear erases it`() {
        val store = store()
        store.write(byteArrayOf(1, 2, 3))

        store.clear()

        assertNull(store().read())
    }

    @Test
    fun `the panic wipe of the identity erases it with the keys`() {
        val identity = identity()
        store(identity).write(byteArrayOf(1, 2, 3))

        identity.clearIdentityData()

        assertNull(store().read())
    }

    @Test
    fun `a kept report survives a restart through the real store`() = runBlocking {
        val myPeerID = "0102030405060708"
        val now = 1_800_000_000_000L
        val sent = HealthReportBroadcast.packet(myPeerID, byteArrayOf(2, 1, 9), timestamp = now - 1_000)
            .copy(signature = ByteArray(64) { 7 })

        OwnHealthReportKeeper(myPeerID, store(), nowMs = { now }).keep(sent)
        val restored = OwnHealthReportKeeper(myPeerID, store(), nowMs = { now }).latest()

        assertEquals(sent, restored)
        assertEquals(PacketIdUtil.computeIdHex(sent), PacketIdUtil.computeIdHex(restored!!))
    }
}
