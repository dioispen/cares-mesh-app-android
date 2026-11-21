package com.bitchat.android.service

import org.junit.Assert.assertEquals
import org.junit.Test

class MeshBackgroundStatusTest {

    @Test
    fun `a running foreground service is active`() {
        assertEquals(MeshBackgroundStatus.ACTIVE, resolve(inForeground = true, enabled = true, permissions = true))
    }

    @Test
    fun `background operation turned off is reported before missing permissions`() {
        assertEquals(MeshBackgroundStatus.BACKGROUND_DISABLED, resolve(inForeground = false, enabled = false, permissions = false))
        assertEquals(MeshBackgroundStatus.BACKGROUND_DISABLED, resolve(inForeground = false, enabled = false, permissions = true))
    }

    @Test
    fun `background on without Bluetooth permissions cannot start the service`() {
        assertEquals(MeshBackgroundStatus.PERMISSIONS_MISSING, resolve(inForeground = false, enabled = true, permissions = false))
    }

    @Test
    fun `eligible but not in the foreground is not running`() {
        assertEquals(MeshBackgroundStatus.NOT_RUNNING, resolve(inForeground = false, enabled = true, permissions = true))
    }

    @Test
    fun `wire names match the Dart BackgroundOperation enum`() {
        assertEquals(
            listOf("active", "backgroundDisabled", "permissionsMissing", "notRunning"),
            MeshBackgroundStatus.entries.map { it.wireName }
        )
    }

    private fun resolve(inForeground: Boolean, enabled: Boolean, permissions: Boolean) =
        MeshBackgroundStatus.resolve(
            serviceInForeground = inForeground,
            backgroundEnabled = enabled,
            hasBluetoothPermissions = permissions
        )
}
