package com.bitchat.android.flutter

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import com.bitchat.android.BuildConfig
import com.bitchat.android.onboarding.PermissionManager
import com.bitchat.android.onboarding.PermissionType
import com.bitchat.android.service.MeshForegroundService
import com.bitchat.android.service.MeshServicePreferences

/**
 * [SettingsDevice] on Android (#80): permission state from [PermissionManager], the system's
 * prompts and screens started from [activity] (null in a background engine, where every launcher
 * returns false).
 */
internal class AndroidSettingsDevice(
    private val context: Context,
    private val activity: Activity?,
    private val permissionManager: PermissionManager = PermissionManager(context)
) : SettingsDevice {

    override fun permissions(): List<SettingsPermission> =
        permissionManager.getCategorizedPermissions()
            .mapNotNull { category ->
                val settingsCategory = category.type.toSettingsCategory() ?: return@mapNotNull null
                SettingsPermission(
                    category = settingsCategory,
                    permissions = category.permissions,
                    granted = category.isGranted,
                    canPrompt = category.permissions
                        .filterNot(permissionManager::isPermissionGranted)
                        .any { permission ->
                            systemWouldPrompt(
                                wasRequested = permissionManager.wasPermissionRequested(permission),
                                showsRationale = activity?.let {
                                    ActivityCompat.shouldShowRequestPermissionRationale(it, permission)
                                } ?: false
                            )
                        }
                )
            }
            .sortedBy { it.category.ordinal }

    override fun isBluetoothEnabled(): Boolean =
        context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true

    override val appVersion: String = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"

    override fun requestPermissions(permissions: List<String>): Boolean {
        val activity = activity ?: return false
        permissionManager.markPermissionsRequested(permissions)
        ActivityCompat.requestPermissions(activity, permissions.toTypedArray(), REQUEST_CODE)
        return true
    }

    override fun openAppSettings(): Boolean = start(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
    )

    // Apps targeting API 33+ cannot switch Bluetooth themselves; the system asks the user instead.
    @SuppressLint("MissingPermission")
    override fun requestEnableBluetooth(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !permissionManager.isPermissionGranted(Manifest.permission.BLUETOOTH_CONNECT)
        ) {
            throw SecurityException("BLUETOOTH_CONNECT is not granted")
        }
        return start(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
    }

    // The direct request, as onboarding's BatteryOptimizationManager makes it; the list of apps
    // when a device has no such screen.
    @SuppressLint("BatteryLife")
    override fun requestIgnoreBatteryOptimization(): Boolean {
        val activity = activity ?: return false
        val request = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
        val intent = if (request.resolveActivity(activity.packageManager) != null) {
            request
        } else {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        }
        return start(intent)
    }

    private fun start(intent: Intent): Boolean {
        val activity = activity ?: return false
        activity.startActivity(intent)
        return true
    }

    private fun PermissionType.toSettingsCategory(): SettingsPermissionCategory? = when (this) {
        PermissionType.PRECISE_LOCATION -> SettingsPermissionCategory.LOCATION
        PermissionType.BACKGROUND_LOCATION -> SettingsPermissionCategory.BACKGROUND_LOCATION
        PermissionType.NEARBY_DEVICES -> SettingsPermissionCategory.NEARBY_DEVICES
        PermissionType.NOTIFICATIONS -> SettingsPermissionCategory.NOTIFICATIONS
        PermissionType.BATTERY_OPTIMIZATION -> SettingsPermissionCategory.BATTERY_OPTIMIZATION
        // Wi-Fi Aware has no switch in the Flutter UI (#80, out of scope).
        else -> null
    }

    private companion object {
        const val REQUEST_CODE = 1002
    }
}

/** [MeshBackgroundSettings] backed by upstream's [MeshServicePreferences] and [MeshForegroundService]. */
internal class UpstreamMeshBackgroundSettings(private val context: Context) : MeshBackgroundSettings {
    override var backgroundEnabled: Boolean
        get() = MeshServicePreferences.isBackgroundEnabled(true)
        set(value) = MeshServicePreferences.setBackgroundEnabled(value)

    override var autoStartEnabled: Boolean
        get() = MeshServicePreferences.isAutoStartEnabled(true)
        set(value) = MeshServicePreferences.setAutoStartEnabled(value)

    override var notificationAutoRestore: Boolean
        get() = MeshServicePreferences.isNotificationAutoRestoreEnabled()
        set(value) = MeshServicePreferences.setNotificationAutoRestoreEnabled(value)

    override fun startForegroundService() = MeshForegroundService.start(context)
    override fun stopForegroundService() = MeshForegroundService.stop(context)
    override fun repostNotification() = MeshForegroundService.repostNotification(context)
}
