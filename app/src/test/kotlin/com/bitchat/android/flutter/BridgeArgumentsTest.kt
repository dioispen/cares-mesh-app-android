package com.bitchat.android.flutter

import com.bitchat.android.testsupport.RecordingResult
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeArgumentsTest {

    @Test
    fun `a string argument is read from the call's argument map`() {
        val call = MethodCall("m", mapOf("text" to "hi", "count" to 3, "none" to null))

        assertEquals("hi", call.stringArgument("text"))
        assertNull("another type reads as missing", call.stringArgument("count"))
        assertNull(call.stringArgument("none"))
        assertNull(call.stringArgument("absent"))
    }

    @Test
    fun `a call without an argument map has no arguments`() {
        listOf(MethodCall("m", null), MethodCall("m", "hi"), MethodCall("m", listOf("hi"))).forEach { call ->
            assertNull(call.stringArgument("text"))
            assertTrue("an optional argument may be missing", call.hasOptionalString("text"))
        }
    }

    @Test
    fun `an optional string argument may be absent or null but not another type`() {
        val call = MethodCall("m", mapOf("text" to "hi", "flag" to true, "none" to null))

        assertTrue(call.hasOptionalString("text"))
        assertTrue(call.hasOptionalString("none"))
        assertTrue(call.hasOptionalString("absent"))
        assertFalse(call.hasOptionalString("flag"))
    }

    @Test
    fun `invalid arguments are answered INVALID_ARGUMENT, naming the method and what it expects`() {
        val messages = mutableListOf<String?>()
        val result = object : MethodChannel.Result by RecordingResult() {
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                messages += "$errorCode: $errorMessage"
            }
        }

        result.invalidArguments(MethodCall("chat_setNickname", null), "{nickname: String}")

        assertEquals(listOf("INVALID_ARGUMENT: chat_setNickname expects {nickname: String}"), messages)
    }
}
