package com.bitchat.android.flutter

import android.os.Build
import com.bitchat.android.testsupport.FakeAndroidKeyStore
import com.bitchat.android.testsupport.RecordingResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.mock
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import kotlin.coroutines.CoroutineContext

/**
 * The system half of the bridge keeps the encrypted identity store (keystore and disk) off the
 * main thread: it is not opened while the engine is set up, and `isRegistered` reads it on the I/O
 * dispatcher before answering.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class BitchatFlutterChannelsTest {

    private val main = StandardTestDispatcher()
    private val io = CountingDispatcher(StandardTestDispatcher(main.scheduler))
    private var channels: BitchatFlutterChannels? = null

    @After
    fun tearDown() {
        channels?.destroy()
        FakeAndroidKeyStore.uninstall()
    }

    @Test
    fun `setting up the channels opens no identity store`() {
        // Robolectric has no AndroidKeyStore: opening the encrypted identity store here would throw.
        channels = newChannels()
    }

    @Test
    fun `isRegistered is answered once the identity store was read on the I-O dispatcher`() {
        FakeAndroidKeyStore.install()
        val channels = newChannels().also { channels = it }
        val result = RecordingResult()

        val claimed = channels.handle(MethodCall("isRegistered", null), result)

        assertTrue(claimed)
        assertEquals("not answered from the main thread's call", emptyList<String>(), result.calls)
        main.scheduler.advanceUntilIdle()
        assertTrue("read on the I/O dispatcher", io.dispatches > 0)
        // A fresh store holds no identity yet.
        assertEquals(listOf("success:false"), result.calls)
    }

    private fun newChannels() = BitchatFlutterChannels(
        context = RuntimeEnvironment.getApplication(),
        messenger = mock<BinaryMessenger>(),
        scope = CoroutineScope(main + Job()),
        ioDispatcher = io
    )

    /** [delegate], counting the work dispatched to it. */
    private class CountingDispatcher(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        var dispatches = 0
            private set

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatches++
            delegate.dispatch(context, block)
        }
    }
}
