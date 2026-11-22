package com.bitchat.android.mesh

import com.bitchat.android.mesh.PowerManager.BleAdvertiseMode
import com.bitchat.android.mesh.PowerManager.BleTxPower
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PowerProfileResolverTest {

    @Test
    fun `background normal without peers scans four seconds every thirty at balanced scan mode`() {
        val profile = resolve(battery = 80, background = true, peers = false)

        assertEquals(PowerManager.BatteryBand.NORMAL, profile.batteryBand)
        assertEquals(4_000L, profile.ble.scanOnMs)
        assertEquals(26_000L, profile.ble.scanOffMs)
        assertEquals(PowerManager.BleScanMode.BALANCED, profile.ble.scanMode)
        assertFalse(profile.ble.continuousScan)
        assertEquals(8, profile.ble.maxConnections)
        assertEquals(60_000L, profile.meshAnnouncementIntervalMs)
    }

    @Test
    fun `an isolated background phone keeps the longer window at every battery level`() {
        for (battery in listOf(80, 20, 10)) {
            val profile = resolve(battery = battery, background = true, peers = false)

            assertEquals("$battery%", 4_000L, profile.ble.scanOnMs)
            assertEquals("$battery%", 26_000L, profile.ble.scanOffMs)
            assertEquals("$battery%", PowerManager.BleScanMode.BALANCED, profile.ble.scanMode)
        }
    }

    @Test
    fun `background with direct peers keeps one second every thirty at low power scan mode`() {
        val profile = resolve(battery = 80, background = true, peers = true)

        assertEquals(1_000L, profile.ble.scanOnMs)
        assertEquals(29_000L, profile.ble.scanOffMs)
        assertEquals(PowerManager.BleScanMode.LOW_POWER, profile.ble.scanMode)
    }

    @Test
    fun `foreground scan modes still follow the power mode`() {
        assertEquals(PowerManager.BleScanMode.BALANCED, resolve(battery = 80, background = false).ble.scanMode)
        assertEquals(PowerManager.BleScanMode.LOW_POWER, resolve(battery = 20, background = false).ble.scanMode)
        assertEquals(PowerManager.BleScanMode.LOW_POWER, resolve(battery = 10, background = false).ble.scanMode)
        assertEquals(
            PowerManager.BleScanMode.LOW_LATENCY,
            PowerProfileResolver.resolve(80, isCharging = true, isBackground = false, hasDirectPeers = false).ble.scanMode
        )
    }

    @Test
    fun `with direct peers each mode keeps its upstream advertising`() {
        assertEquals(advertise(BleAdvertiseMode.BALANCED, BleTxPower.MEDIUM), resolve(80, false, peers = true).advertise)
        assertEquals(advertise(BleAdvertiseMode.LOW_POWER, BleTxPower.LOW), resolve(80, true, peers = true).advertise)
        assertEquals(advertise(BleAdvertiseMode.LOW_POWER, BleTxPower.ULTRA_LOW), resolve(10, true, peers = true).advertise)
        assertEquals(
            advertise(BleAdvertiseMode.LOW_LATENCY, BleTxPower.HIGH),
            PowerProfileResolver.resolve(80, isCharging = true, isBackground = false, hasDirectPeers = true).advertise
        )
    }

    @Test
    fun `without direct peers the phone advertises balanced at high power`() {
        val isolated = advertise(BleAdvertiseMode.BALANCED, BleTxPower.HIGH)

        assertEquals(isolated, resolve(80, background = true, peers = false).advertise)
        assertEquals(isolated, resolve(20, background = true, peers = false).advertise)
        assertEquals(isolated, resolve(80, background = false, peers = false).advertise)
        assertEquals(isolated, resolve(20, background = false, peers = false).advertise)
    }

    @Test
    fun `isolation never lowers performance advertising`() {
        assertEquals(
            advertise(BleAdvertiseMode.LOW_LATENCY, BleTxPower.HIGH),
            PowerProfileResolver.resolve(80, isCharging = true, isBackground = false, hasDirectPeers = false).advertise
        )
    }

    @Test
    fun `isolated at critical battery advertises low power at medium power`() {
        val critical = advertise(BleAdvertiseMode.LOW_POWER, BleTxPower.MEDIUM)

        assertEquals(critical, resolve(10, background = true, peers = false).advertise)
        assertEquals(critical, resolve(10, background = false, peers = false).advertise)
    }

    @Test
    fun `background low profile uses selected wifi and nostr cadence`() {
        val profile = resolve(battery = 20, background = true)

        assertEquals(PowerManager.BatteryBand.LOW, profile.batteryBand)
        assertEquals(20_000L, profile.wifiAware.tcpKeepAliveMs)
        assertEquals(120_000L, profile.wifiAware.discoveryKeepAliveMs)
        assertEquals(120_000L, profile.wifiAware.connectionMaintenanceMs)
        assertEquals(600_000L, profile.wifiAware.discoveryIdleRefreshMs)
        assertEquals(900_000L, profile.wifiAware.discoveryStaleMs)
        assertEquals(600_000L, profile.nostr.presenceHeartbeatMinMs)
        assertEquals(600_000L, profile.nostr.subscriptionValidationMs)
        assertEquals(120_000L, profile.meshAnnouncementIntervalMs)
    }

    @Test
    fun `background critical profile uses slowest wifi and nostr cadence without reducing connections`() {
        val profile = resolve(battery = 10, background = true, peers = true)

        assertEquals(PowerManager.BatteryBand.CRITICAL, profile.batteryBand)
        assertEquals(30_000L, profile.wifiAware.tcpKeepAliveMs)
        assertEquals(180_000L, profile.wifiAware.discoveryKeepAliveMs)
        assertEquals(180_000L, profile.wifiAware.connectionMaintenanceMs)
        assertEquals(900_000L, profile.wifiAware.discoveryIdleRefreshMs)
        assertEquals(1_200_000L, profile.wifiAware.discoveryStaleMs)
        assertEquals(900_000L, profile.nostr.presenceHeartbeatMinMs)
        assertEquals(900_000L, profile.nostr.subscriptionValidationMs)
        assertEquals(300_000L, profile.meshAnnouncementIntervalMs)
        assertEquals(8, profile.ble.maxConnections)
    }

    @Test
    fun `foreground normal preserves balanced BLE cadence`() {
        val profile = resolve(battery = 80, background = false)

        assertEquals(PowerManager.PowerMode.BALANCED, profile.mode)
        assertEquals(8_000L, profile.ble.scanOnMs)
        assertEquals(2_000L, profile.ble.scanOffMs)
        assertEquals(5_000L, profile.wifiAware.tcpKeepAliveMs)
        assertEquals(30_000L, profile.meshAnnouncementIntervalMs)
    }

    @Test
    fun `foreground charging is performance but background charging stays power limited`() {
        val foreground = PowerProfileResolver.resolve(80, true, false, false)
        val background = PowerProfileResolver.resolve(80, true, true, false)

        assertEquals(PowerManager.PowerMode.PERFORMANCE, foreground.mode)
        assertTrue(foreground.ble.continuousScan)
        assertEquals(PowerManager.PowerMode.POWER_SAVER, background.mode)
        assertFalse(background.ble.continuousScan)
        assertEquals(26_000L, background.ble.scanOffMs)
    }

    @Test
    fun `battery thresholds are inclusive`() {
        assertEquals(PowerManager.BatteryBand.NORMAL, resolve(21, true).batteryBand)
        assertEquals(PowerManager.BatteryBand.LOW, resolve(20, true).batteryBand)
        assertEquals(PowerManager.BatteryBand.LOW, resolve(11, true).batteryBand)
        assertEquals(PowerManager.BatteryBand.CRITICAL, resolve(10, true).batteryBand)
    }

    private fun resolve(
        battery: Int,
        background: Boolean,
        peers: Boolean = false
    ) = PowerProfileResolver.resolve(
        batteryLevel = battery,
        isCharging = false,
        isBackground = background,
        hasDirectPeers = peers
    )

    private fun advertise(mode: BleAdvertiseMode, txPower: BleTxPower) = PowerManager.AdvertiseProfile(mode, txPower)
}
