package com.bitchat.android.flutter

import com.bitchat.android.testsupport.RecordingResult
import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeMethodDispatcherTest {

    @Test
    fun `unknown method is answered with notImplemented`() {
        val result = RecordingResult()
        val dispatcher = BridgeMethodDispatcher(
            listOf(
                BridgeMethodHandler { _, _ -> false },
                BridgeMethodHandler { _, _ -> false }
            )
        )

        dispatcher.onMethodCall(MethodCall("noSuchMethod", null), result)

        assertEquals(listOf("notImplemented"), result.calls)
    }

    @Test
    fun `dispatcher without handlers answers notImplemented`() {
        val result = RecordingResult()

        BridgeMethodDispatcher(emptyList()).onMethodCall(MethodCall("anything", null), result)

        assertEquals(listOf("notImplemented"), result.calls)
    }

    @Test
    fun `first handler that claims the call wins and later handlers are not consulted`() {
        val consulted = mutableListOf<String>()
        val result = RecordingResult()
        val dispatcher = BridgeMethodDispatcher(
            listOf(
                BridgeMethodHandler { call, r ->
                    consulted += "system"
                    if (call.method == "getSystemStatus") {
                        r.success("status")
                        true
                    } else {
                        false
                    }
                },
                BridgeMethodHandler { _, _ ->
                    consulted += "chat"
                    true
                }
            )
        )

        dispatcher.onMethodCall(MethodCall("getSystemStatus", null), result)

        assertEquals(listOf("system"), consulted)
        assertEquals(listOf("success:status"), result.calls)
    }

    @Test
    fun `call declined by the system bridge falls through to the next handler`() {
        val result = RecordingResult()
        val dispatcher = BridgeMethodDispatcher(
            listOf(
                BridgeMethodHandler { _, _ -> false },
                BridgeMethodHandler { call, r ->
                    if (call.method == "chatOnly") {
                        r.success(null)
                        true
                    } else {
                        false
                    }
                }
            )
        )

        dispatcher.onMethodCall(MethodCall("chatOnly", null), result)

        assertEquals(listOf("success:null"), result.calls)
    }

    @Test
    fun `result is completed exactly once for every dispatched call`() {
        val dispatcher = BridgeMethodDispatcher(
            listOf(
                BridgeMethodHandler { call, r ->
                    if (call.method == "known") {
                        r.success(true)
                        true
                    } else {
                        false
                    }
                }
            )
        )

        listOf("known", "unknown").forEach { method ->
            val result = RecordingResult()
            dispatcher.onMethodCall(MethodCall(method, null), result)
            assertTrue("$method completed ${result.calls}", result.calls.size == 1)
        }
    }
}
