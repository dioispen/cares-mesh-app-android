package com.bitchat.android.onboarding

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import com.bitchat.android.ui.debug.DebugPreferenceManager
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * CARES ships with the Wi-Fi Aware transport enabled, so its runtime permission now reaches
 * every user. These tests pin the two halves of that decision: the permission is asked for,
 * but declining it must not block the BLE mesh the way a missing Bluetooth permission does.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class WifiAwarePermissionGatingTest {

    private lateinit var application: Application

    @Before
    fun setUp() {
        application = ApplicationProvider.getApplicationContext()
        application.getSharedPreferences("bitchat_debug_settings", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        DebugPreferenceManager.init(application)

        shadowOf(application).grantPermissions(
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION
        )
        shadowOf(application).denyPermissions(Manifest.permission.NEARBY_WIFI_DEVICES)
    }

    private fun setWifiAwareSupported(supported: Boolean) {
        shadowOf(application.packageManager)
            .setSystemFeature(PackageManager.FEATURE_WIFI_AWARE, supported)
    }

    @Test
    fun `wifi aware transport is enabled by default`() {
        assertTrue(DebugPreferenceManager.getWifiAwareEnabled())
    }

    @Test
    fun `supported device is asked for the wifi aware permission`() {
        setWifiAwareSupported(true)
        val permissionManager = PermissionManager(application)

        assertTrue(
            Manifest.permission.NEARBY_WIFI_DEVICES in permissionManager.getPermissionsToRequest()
        )
    }

    @Test
    fun `wifi aware permission never blocks the mesh`() {
        setWifiAwareSupported(true)
        val permissionManager = PermissionManager(application)

        // Not in the critical set, so a denial leaves onboarding and the Flutter setup screen
        // passable and the mesh comes up over BLE alone.
        assertFalse(
            Manifest.permission.NEARBY_WIFI_DEVICES in permissionManager.getRequiredPermissions()
        )
        assertTrue(permissionManager.areRequiredPermissionsGranted())
    }

    @Test
    fun `device without wifi aware is never prompted`() {
        setWifiAwareSupported(false)
        val permissionManager = PermissionManager(application)

        assertFalse(
            Manifest.permission.NEARBY_WIFI_DEVICES in permissionManager.getPermissionsToRequest()
        )
        assertTrue(permissionManager.areRequiredPermissionsGranted())
    }
}
