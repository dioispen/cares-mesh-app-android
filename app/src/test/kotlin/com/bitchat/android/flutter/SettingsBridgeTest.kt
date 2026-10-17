package com.bitchat.android.flutter

import com.bitchat.android.testsupport.RecordingResult
import io.flutter.plugin.common.MethodCall
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsBridgeTest {

    private val dispatcher = StandardTestDispatcher()
    private val device = FakeDevice()
    private val mesh = FakeMeshSettings()
    private var panic: () -> Deferred<Boolean>? = { CompletableDeferred(true) }
    private val bridge = SettingsBridge(
        device = device,
        meshSettings = mesh,
        panicClear = { panic() },
        scope = CoroutineScope(dispatcher + Job())
    )

    private fun call(method: String, arguments: Any? = null): RecordingResult {
        val result = RecordingResult()
        assertTrue("$method is claimed", bridge.handle(MethodCall(method, arguments), result))
        dispatcher.scheduler.advanceUntilIdle()
        return result
    }

    // ── state ────────────────────────────────────────────────────────────────

    @Test
    fun `the state lists every permission category the device asks for, in its order`() {
        device.permissions = listOf(
            permission(SettingsPermissionCategory.NEARBY_DEVICES, granted = true),
            permission(SettingsPermissionCategory.LOCATION, granted = false),
            permission(SettingsPermissionCategory.BATTERY_OPTIMIZATION, granted = true)
        )

        val state = call(SettingsBridge.METHOD_GET_STATE).values.single() as Map<*, *>

        assertEquals(
            listOf(
                mapOf("category" to "nearbyDevices", "granted" to true),
                mapOf("category" to "location", "granted" to false),
                mapOf("category" to "batteryOptimization", "granted" to true)
            ),
            state["permissions"]
        )
    }

    @Test
    fun `the state carries Bluetooth, the mesh preferences and the app version`() {
        device.bluetoothEnabled = false
        mesh.backgroundEnabled = true
        mesh.autoStartEnabled = false
        mesh.notificationAutoRestore = true

        val state = call(SettingsBridge.METHOD_GET_STATE).values.single() as Map<*, *>

        assertEquals(false, state["bluetoothEnabled"])
        assertEquals(true, state["backgroundEnabled"])
        assertEquals(false, state["autoStartEnabled"])
        assertEquals(true, state["notificationAutoRestore"])
        assertEquals("9.9.9 (99)", state["appVersion"])
    }

    @Test
    fun `methods it does not own are left to the next handler`() {
        val result = RecordingResult()

        assertFalse(bridge.handle(MethodCall("chat_sendMessage", null), result))
        assertEquals(emptyList<String>(), result.calls)
    }

    // ── permissions ──────────────────────────────────────────────────────────

    @Test
    fun `a permission not granted yet is asked for with the system prompt`() {
        device.permissions = listOf(
            permission(SettingsPermissionCategory.NEARBY_DEVICES, granted = false, permissions = listOf("scan", "connect"))
        )

        val result = call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "nearbyDevices"))

        assertEquals(listOf("success:${SettingsBridge.ACTION_PROMPTED}"), result.calls)
        assertEquals(listOf("prompt:[scan, connect]"), device.actions)
    }

    @Test
    fun `a granted permission opens the app's system settings, since only the user can revoke it`() {
        device.permissions = listOf(permission(SettingsPermissionCategory.NOTIFICATIONS, granted = true))

        val result = call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "notifications"))

        assertEquals(listOf("success:${SettingsBridge.ACTION_OPENED_APP_SETTINGS}"), result.calls)
        assertEquals(listOf("appSettings"), device.actions)
    }

    @Test
    fun `a permission the system would no longer prompt for opens the app's system settings`() {
        device.permissions = listOf(
            permission(SettingsPermissionCategory.LOCATION, granted = false, canPrompt = false)
        )

        val result = call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "location"))

        assertEquals(listOf("success:${SettingsBridge.ACTION_OPENED_APP_SETTINGS}"), result.calls)
        assertEquals(listOf("appSettings"), device.actions)
    }

    @Test
    fun `background location asks for location first while location itself is not granted`() {
        device.permissions = listOf(
            permission(SettingsPermissionCategory.LOCATION, granted = false, permissions = listOf("coarse", "fine")),
            permission(SettingsPermissionCategory.BACKGROUND_LOCATION, granted = false, permissions = listOf("background"))
        )

        call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "backgroundLocation"))

        assertEquals(listOf("prompt:[coarse, fine]"), device.actions)
    }

    @Test
    fun `background location is asked for once location is granted`() {
        device.permissions = listOf(
            permission(SettingsPermissionCategory.LOCATION, granted = true),
            permission(SettingsPermissionCategory.BACKGROUND_LOCATION, granted = false, permissions = listOf("background"))
        )

        call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "backgroundLocation"))

        assertEquals(listOf("prompt:[background]"), device.actions)
    }

    @Test
    fun `battery optimization not yet lifted asks the system to exempt the app`() {
        device.permissions = listOf(permission(SettingsPermissionCategory.BATTERY_OPTIMIZATION, granted = false))

        val result = call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "batteryOptimization"))

        assertEquals(listOf("success:${SettingsBridge.ACTION_REQUESTED_BATTERY_EXEMPTION}"), result.calls)
        assertEquals(listOf("batteryExemption"), device.actions)
    }

    @Test
    fun `a category this device does not ask for is refused`() {
        device.permissions = listOf(permission(SettingsPermissionCategory.LOCATION, granted = true))

        val result = call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "notifications"))

        assertEquals(listOf("error:${SettingsBridge.ERROR_UNAVAILABLE}"), result.calls)
        assertEquals(emptyList<String>(), device.actions)
    }

    @Test
    fun `an unknown or missing category is an invalid argument`() {
        assertEquals(
            listOf("error:$INVALID_ARGUMENT"),
            call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "camera")).calls
        )
        assertEquals(listOf("error:$INVALID_ARGUMENT"), call(SettingsBridge.METHOD_REQUEST_PERMISSION).calls)
    }

    @Test
    fun `system screens that cannot be opened without an activity answer an error`() {
        device.permissions = listOf(permission(SettingsPermissionCategory.LOCATION, granted = false))
        device.canLaunch = false

        assertEquals(
            listOf("error:${SettingsBridge.ERROR_NO_ACTIVITY}"),
            call(SettingsBridge.METHOD_REQUEST_PERMISSION, mapOf("category" to "location")).calls
        )
        assertEquals(listOf("error:${SettingsBridge.ERROR_NO_ACTIVITY}"), call(SettingsBridge.METHOD_OPEN_APP_SETTINGS).calls)
        assertEquals(
            listOf("error:${SettingsBridge.ERROR_NO_ACTIVITY}"),
            call(SettingsBridge.METHOD_REQUEST_ENABLE_BLUETOOTH).calls
        )
        assertEquals(
            listOf("error:${SettingsBridge.ERROR_NO_ACTIVITY}"),
            call(SettingsBridge.METHOD_REQUEST_IGNORE_BATTERY_OPTIMIZATION).calls
        )
    }

    @Test
    fun `the system screens are opened on request`() {
        assertEquals(listOf("success:null"), call(SettingsBridge.METHOD_OPEN_APP_SETTINGS).calls)
        assertEquals(listOf("success:null"), call(SettingsBridge.METHOD_REQUEST_ENABLE_BLUETOOTH).calls)
        assertEquals(listOf("success:null"), call(SettingsBridge.METHOD_REQUEST_IGNORE_BATTERY_OPTIMIZATION).calls)
        assertEquals(listOf("appSettings", "enableBluetooth", "batteryExemption"), device.actions)
    }

    @Test
    fun `asking to turn Bluetooth on without the connect permission answers that error`() {
        device.enableBluetoothFailure = SecurityException("BLUETOOTH_CONNECT")

        assertEquals(
            listOf("error:${SettingsBridge.ERROR_PERMISSION_REQUIRED}"),
            call(SettingsBridge.METHOD_REQUEST_ENABLE_BLUETOOTH).calls
        )
    }

    // ── mesh background ──────────────────────────────────────────────────────

    @Test
    fun `turning background off stores it and stops the foreground service`() {
        mesh.backgroundEnabled = true

        assertEquals(listOf("success:null"), call(SettingsBridge.METHOD_SET_BACKGROUND_ENABLED, mapOf("enabled" to false)).calls)

        assertFalse(mesh.backgroundEnabled)
        assertEquals(listOf("stop"), mesh.actions)
    }

    @Test
    fun `turning background on stores it and starts the foreground service`() {
        mesh.backgroundEnabled = false

        call(SettingsBridge.METHOD_SET_BACKGROUND_ENABLED, mapOf("enabled" to true))

        assertTrue(mesh.backgroundEnabled)
        assertEquals(listOf("start"), mesh.actions)
    }

    @Test
    fun `auto start on boot is stored`() {
        call(SettingsBridge.METHOD_SET_AUTO_START_ENABLED, mapOf("enabled" to false))

        assertFalse(mesh.autoStartEnabled)
        assertEquals(emptyList<String>(), mesh.actions)
    }

    @Test
    fun `changing notification auto-restore stores it and reposts the notification at once`() {
        mesh.backgroundEnabled = true

        call(SettingsBridge.METHOD_SET_NOTIFICATION_AUTO_RESTORE, mapOf("enabled" to true))

        assertTrue(mesh.notificationAutoRestore)
        assertEquals(listOf("repost"), mesh.actions)
    }

    @Test
    fun `notification auto-restore reposts nothing while background is off`() {
        mesh.backgroundEnabled = false

        call(SettingsBridge.METHOD_SET_NOTIFICATION_AUTO_RESTORE, mapOf("enabled" to true))

        assertTrue(mesh.notificationAutoRestore)
        assertEquals(emptyList<String>(), mesh.actions)
    }

    @Test
    fun `a switch without a boolean is an invalid argument and changes nothing`() {
        for (method in listOf(
            SettingsBridge.METHOD_SET_BACKGROUND_ENABLED,
            SettingsBridge.METHOD_SET_AUTO_START_ENABLED,
            SettingsBridge.METHOD_SET_NOTIFICATION_AUTO_RESTORE
        )) {
            assertEquals(listOf("error:$INVALID_ARGUMENT"), call(method, mapOf("enabled" to "yes")).calls)
        }
        assertEquals(emptyList<String>(), mesh.actions)
        assertEquals(FakeMeshSettings().snapshot(), mesh.snapshot())
    }

    // ── panic clear ──────────────────────────────────────────────────────────

    @Test
    fun `panic clear answers only once the native wipe has finished`() {
        val wipe = CompletableDeferred<Boolean>()
        panic = { wipe }
        val result = RecordingResult()

        bridge.handle(MethodCall(SettingsBridge.METHOD_PANIC_CLEAR, null), result)
        dispatcher.scheduler.advanceUntilIdle()
        assertEquals(emptyList<String>(), result.calls)

        wipe.complete(true)
        dispatcher.scheduler.advanceUntilIdle()
        assertEquals(listOf("success:null"), result.calls)
    }

    @Test
    fun `a panic clear that could not erase everything answers an error`() {
        panic = { CompletableDeferred(false) }

        assertEquals(listOf("error:${SettingsBridge.ERROR_PANIC_INCOMPLETE}"), call(SettingsBridge.METHOD_PANIC_CLEAR).calls)
    }

    @Test
    fun `a panic clear already running answers an error`() {
        panic = { null }

        assertEquals(listOf("error:${SettingsBridge.ERROR_PANIC_IN_PROGRESS}"), call(SettingsBridge.METHOD_PANIC_CLEAR).calls)
    }

    @Test
    fun `a panic clear that failed answers an error`() {
        panic = { CompletableDeferred<Boolean>().apply { completeExceptionally(IllegalStateException("disk")) } }

        assertEquals(listOf("error:${SettingsBridge.ERROR_PANIC_FAILED}"), call(SettingsBridge.METHOD_PANIC_CLEAR).calls)
    }

    // ── prompt decision ──────────────────────────────────────────────────────

    @Test
    fun `the system prompts for a permission never asked for, or one it explains a denial of`() {
        assertTrue(systemWouldPrompt(wasRequested = false, showsRationale = false))
        assertTrue(systemWouldPrompt(wasRequested = true, showsRationale = true))
        assertFalse("denied for good", systemWouldPrompt(wasRequested = true, showsRationale = false))
    }

    // ── fakes ────────────────────────────────────────────────────────────────

    private fun permission(
        category: SettingsPermissionCategory,
        granted: Boolean,
        canPrompt: Boolean = true,
        permissions: List<String> = listOf(category.wireName)
    ) = SettingsPermission(category, permissions, granted, canPrompt)

    private class FakeDevice : SettingsDevice {
        var permissions: List<SettingsPermission> = emptyList()
        var bluetoothEnabled = true
        var canLaunch = true
        var enableBluetoothFailure: Exception? = null
        val actions = mutableListOf<String>()

        override fun permissions() = permissions
        override fun isBluetoothEnabled() = bluetoothEnabled
        override val appVersion = "9.9.9 (99)"

        override fun requestPermissions(permissions: List<String>) = launch("prompt:$permissions")
        override fun openAppSettings() = launch("appSettings")
        override fun requestEnableBluetooth(): Boolean {
            enableBluetoothFailure?.let { throw it }
            return launch("enableBluetooth")
        }
        override fun requestIgnoreBatteryOptimization() = launch("batteryExemption")

        private fun launch(action: String): Boolean {
            if (!canLaunch) return false
            actions += action
            return true
        }
    }

    private class FakeMeshSettings : MeshBackgroundSettings {
        override var backgroundEnabled = true
        override var autoStartEnabled = true
        override var notificationAutoRestore = false
        val actions = mutableListOf<String>()

        override fun startForegroundService() { actions += "start" }
        override fun stopForegroundService() { actions += "stop" }
        override fun repostNotification() { actions += "repost" }

        fun snapshot() = listOf(backgroundEnabled, autoStartEnabled, notificationAutoRestore)
    }
}
