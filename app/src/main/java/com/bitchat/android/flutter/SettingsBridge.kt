package com.bitchat.android.flutter

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

/**
 * The settings screen's half of the Flutter bridge (#80).
 *
 * It reads and changes what the Flutter settings screen shows: the permissions the setup flow asks
 * for, Bluetooth, battery optimization ([SettingsDevice]), the mesh service's background
 * preferences ([MeshBackgroundSettings]), and upstream's panic clear. Everything it reads comes
 * from upstream's own sources — permissions from `PermissionManager`, preferences from
 * `MeshServicePreferences` — and nothing is cached here: the screen asks for [METHOD_GET_STATE]
 * again whenever it comes back from the system's settings.
 *
 * Android does not let an app revoke its own permissions, so [METHOD_REQUEST_PERMISSION] either
 * shows the system prompt (not granted yet, and the system would still prompt) or opens the app's
 * page in the system settings (granted, or denied for good) where the user switches it.
 *
 * Every refusal is answered as a `PlatformException` error code (`ERROR_*`); none is swallowed.
 * Methods are named `settings_<verb><Object>`.
 *
 * It owns no channel: [BitchatFlutterChannels] offers it the methods it does not recognise.
 */
class SettingsBridge(
    private val device: SettingsDevice,
    private val meshSettings: MeshBackgroundSettings,
    /** Upstream's `ChatViewModel.panicClearAllData`: true once everything was erased, null while one runs. */
    private val panicClear: () -> Deferred<Boolean>?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
) : BridgeMethodHandler {

    override fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            METHOD_GET_STATE -> result.success(state())
            METHOD_REQUEST_PERMISSION -> requestPermission(call, result)
            METHOD_OPEN_APP_SETTINGS -> answerLaunch(result, device.openAppSettings())
            METHOD_REQUEST_ENABLE_BLUETOOTH -> requestEnableBluetooth(result)
            METHOD_REQUEST_IGNORE_BATTERY_OPTIMIZATION -> answerLaunch(result, device.requestIgnoreBatteryOptimization())
            METHOD_SET_BACKGROUND_ENABLED -> setSwitch(call, result) { enabled ->
                // As upstream's AboutSheet: the preference first, then the service follows it.
                meshSettings.backgroundEnabled = enabled
                if (enabled) meshSettings.startForegroundService() else meshSettings.stopForegroundService()
            }
            METHOD_SET_AUTO_START_ENABLED -> setSwitch(call, result) { enabled ->
                meshSettings.autoStartEnabled = enabled
            }
            METHOD_SET_NOTIFICATION_AUTO_RESTORE -> setSwitch(call, result) { enabled ->
                meshSettings.notificationAutoRestore = enabled
                // Without background there is no ongoing notification to rebuild.
                if (meshSettings.backgroundEnabled) meshSettings.repostNotification()
            }
            METHOD_PANIC_CLEAR -> runPanicClear(result)
            else -> return false
        }
        return true
    }

    private fun state(): Map<String, Any?> = mapOf(
        "permissions" to device.permissions().map {
            mapOf("category" to it.category.wireName, "granted" to it.granted)
        },
        "bluetoothEnabled" to device.isBluetoothEnabled(),
        "backgroundEnabled" to meshSettings.backgroundEnabled,
        "autoStartEnabled" to meshSettings.autoStartEnabled,
        "notificationAutoRestore" to meshSettings.notificationAutoRestore,
        "appVersion" to device.appVersion
    )

    private fun requestPermission(call: MethodCall, result: MethodChannel.Result) {
        val category = call.stringArgument("category")?.let(SettingsPermissionCategory::fromWireName)
            ?: return result.invalidArguments(call, "{category: ${SettingsPermissionCategory.entries.joinToString("|") { it.wireName }}}")
        val permissions = device.permissions()
        var target = permissions.firstOrNull { it.category == category }
            ?: return result.error(ERROR_UNAVAILABLE, "$category is not asked for on this device", null)
        // The system ignores a background location request until location itself is granted.
        if (category == SettingsPermissionCategory.BACKGROUND_LOCATION && !target.granted) {
            permissions.firstOrNull { it.category == SettingsPermissionCategory.LOCATION && !it.granted }?.let { target = it }
        }

        val (launched, action) = when {
            target.granted -> device.openAppSettings() to ACTION_OPENED_APP_SETTINGS
            target.category == SettingsPermissionCategory.BATTERY_OPTIMIZATION ->
                device.requestIgnoreBatteryOptimization() to ACTION_REQUESTED_BATTERY_EXEMPTION
            target.canPrompt -> device.requestPermissions(target.permissions) to ACTION_PROMPTED
            else -> device.openAppSettings() to ACTION_OPENED_APP_SETTINGS
        }
        if (launched) result.success(action) else result.error(ERROR_NO_ACTIVITY, "No activity to show system screens from", null)
    }

    private fun requestEnableBluetooth(result: MethodChannel.Result) {
        val launched = try {
            device.requestEnableBluetooth()
        } catch (e: SecurityException) {
            // API 31+: asking to turn Bluetooth on needs BLUETOOTH_CONNECT.
            return result.error(ERROR_PERMISSION_REQUIRED, e.message, null)
        }
        answerLaunch(result, launched)
    }

    private fun answerLaunch(result: MethodChannel.Result, launched: Boolean) {
        if (launched) result.success(null) else result.error(ERROR_NO_ACTIVITY, "No activity to show system screens from", null)
    }

    private inline fun setSwitch(call: MethodCall, result: MethodChannel.Result, apply: (Boolean) -> Unit) {
        val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
            ?: return result.invalidArguments(call, "{enabled: bool}")
        apply(enabled)
        result.success(null)
    }

    /** Answers once upstream's wipe has finished, so Dart only signs out after it. */
    private fun runPanicClear(result: MethodChannel.Result) {
        val wipe = panicClear() ?: return result.error(ERROR_PANIC_IN_PROGRESS, "A panic clear is already running", null)
        scope.launch {
            val complete = try {
                wipe.await()
            } catch (e: Exception) {
                // This engine going away cancels us: nobody is left to answer. The wipe itself
                // being cancelled (its ViewModel cleared) is a failure Dart must hear about.
                ensureActive()
                result.error(ERROR_PANIC_FAILED, e.message, null)
                return@launch
            }
            if (complete) {
                result.success(null)
            } else {
                // Upstream keeps the mesh stopped: it could not prove the conversations were erased.
                result.error(ERROR_PANIC_INCOMPLETE, "The conversation history could not be erased", null)
            }
        }
    }

    /** Stops answering pending calls; the engine is going away. */
    fun destroy() {
        scope.cancel()
    }

    companion object {
        const val METHOD_GET_STATE = "settings_getState"
        const val METHOD_REQUEST_PERMISSION = "settings_requestPermission"
        const val METHOD_OPEN_APP_SETTINGS = "settings_openAppSettings"
        const val METHOD_REQUEST_ENABLE_BLUETOOTH = "settings_requestEnableBluetooth"
        const val METHOD_REQUEST_IGNORE_BATTERY_OPTIMIZATION = "settings_requestIgnoreBatteryOptimization"
        const val METHOD_SET_BACKGROUND_ENABLED = "settings_setBackgroundEnabled"
        const val METHOD_SET_AUTO_START_ENABLED = "settings_setAutoStartEnabled"
        const val METHOD_SET_NOTIFICATION_AUTO_RESTORE = "settings_setNotificationAutoRestore"
        const val METHOD_PANIC_CLEAR = "settings_panicClear"

        /** [METHOD_REQUEST_PERMISSION] showed the system's permission prompt. */
        const val ACTION_PROMPTED = "prompted"
        /** [METHOD_REQUEST_PERMISSION] opened the app's page in the system settings. */
        const val ACTION_OPENED_APP_SETTINGS = "openedAppSettings"
        /** [METHOD_REQUEST_PERMISSION] asked the system to exempt the app from battery optimization. */
        const val ACTION_REQUESTED_BATTERY_EXEMPTION = "requestedBatteryExemption"

        /** There is no activity to show a system prompt or screen from. */
        const val ERROR_NO_ACTIVITY = "NO_ACTIVITY"
        /** The permission category is not asked for on this Android version. */
        const val ERROR_UNAVAILABLE = "UNAVAILABLE"
        /** Asking to turn Bluetooth on needs the nearby devices permission first. */
        const val ERROR_PERMISSION_REQUIRED = "PERMISSION_REQUIRED"
        /** A panic clear is already running. */
        const val ERROR_PANIC_IN_PROGRESS = "PANIC_IN_PROGRESS"
        /** The panic clear ran but could not erase the conversation history; the mesh stays stopped. */
        const val ERROR_PANIC_INCOMPLETE = "PANIC_INCOMPLETE"
        /** The panic clear threw. */
        const val ERROR_PANIC_FAILED = "PANIC_FAILED"
    }
}

/** The permission categories the settings screen lists, named on the wire as [wireName]. */
enum class SettingsPermissionCategory(val wireName: String) {
    LOCATION("location"),
    BACKGROUND_LOCATION("backgroundLocation"),
    NEARBY_DEVICES("nearbyDevices"),
    NOTIFICATIONS("notifications"),
    BATTERY_OPTIMIZATION("batteryOptimization");

    companion object {
        fun fromWireName(name: String): SettingsPermissionCategory? = entries.firstOrNull { it.wireName == name }
    }
}

/**
 * One permission category as it stands now.
 *
 * [canPrompt]: asking for [permissions] would show the system prompt (see [systemWouldPrompt]);
 * when false the user has to switch it in the system settings.
 */
data class SettingsPermission(
    val category: SettingsPermissionCategory,
    val permissions: List<String>,
    val granted: Boolean,
    val canPrompt: Boolean
)

/**
 * Whether the system still shows its prompt for a permission that is not granted: always the
 * first time, and afterwards only while it would show a rationale. A denied permission without a
 * rationale was denied for good ("don't ask again", or twice since Android 11).
 */
internal fun systemWouldPrompt(wasRequested: Boolean, showsRationale: Boolean): Boolean =
    !wasRequested || showsRationale

/** What the settings screen reads from and opens on the device. Launchers return false without an activity. */
interface SettingsDevice {
    /** The categories this device asks for, in the order the screen lists them. */
    fun permissions(): List<SettingsPermission>
    fun isBluetoothEnabled(): Boolean
    val appVersion: String

    fun requestPermissions(permissions: List<String>): Boolean
    fun openAppSettings(): Boolean
    /** `BluetoothAdapter.ACTION_REQUEST_ENABLE`; throws [SecurityException] without BLUETOOTH_CONNECT. */
    fun requestEnableBluetooth(): Boolean
    fun requestIgnoreBatteryOptimization(): Boolean
}

/** The mesh service's background preferences and the service they control. */
interface MeshBackgroundSettings {
    var backgroundEnabled: Boolean
    var autoStartEnabled: Boolean
    var notificationAutoRestore: Boolean

    fun startForegroundService()
    fun stopForegroundService()
    fun repostNotification()
}
