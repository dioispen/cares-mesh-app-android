package com.bitchat.android.experiment

import android.os.Build
import com.bitchat.android.testsupport.RecordingResult
import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Debug builds install the CSV recorder and the field screen's bridge methods (#70). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class ExperimentToolsDebugTest {

    @Test
    fun `install puts the event recorder behind the insertion points and registers the bridge`() {
        ExperimentTools.install(RuntimeEnvironment.getApplication())

        assertTrue(ExperimentTools.recorder is ExperimentEventRecorder)
        val handler = ExperimentTools.bridgeHandlers().single()
        assertTrue(handler is ExperimentBridge)

        val result = RecordingResult()
        handler.handle(MethodCall(ExperimentBridge.METHOD_START_SENDER, mapOf(
            "device" to 1, "count" to 1, "intervalMs" to 0, "ttl" to 3, "startAt" to null, "status" to "安全"
        )), result)
        assertEquals("without the mesh service there is no sender", listOf("error:SERVICE_NOT_READY"), result.calls)
    }
}
