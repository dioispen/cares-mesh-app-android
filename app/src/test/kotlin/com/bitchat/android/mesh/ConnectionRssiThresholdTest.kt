package com.bitchat.android.mesh

import com.bitchat.android.mesh.ConnectionRssiThreshold.Reason
import com.bitchat.android.mesh.PowerManager.PowerMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionRssiThresholdTest {

    @Test
    fun `an isolated phone connects to anything it can hear in every power mode`() {
        for (mode in PowerMode.entries) {
            for (peers in 0..1) {
                assertEquals(
                    "$mode with $peers peers",
                    ConnectionRssiThreshold.Decision(-115, Reason.ISOLATED),
                    resolve(mode, peers = peers, connections = peers * 2)
                )
            }
        }
    }

    @Test
    fun `isolation wins over a full table`() {
        // One peer holding both a client and a server link, with a debug limit of 2.
        assertEquals(Reason.ISOLATED, resolve(PowerMode.ULTRA_LOW_POWER, peers = 1, connections = 2, max = 2).reason)
    }

    @Test
    fun `with free slots the threshold is any audible advertisement except at critical battery`() {
        val expected = mapOf(
            PowerMode.PERFORMANCE to -115,
            PowerMode.BALANCED to -115,
            PowerMode.POWER_SAVER to -115,
            PowerMode.ULTRA_LOW_POWER to -95
        )
        for ((mode, dbm) in expected) {
            assertEquals("$mode", ConnectionRssiThreshold.Decision(dbm, Reason.RELAXED), resolve(mode, peers = 2, connections = 4))
        }
    }

    @Test
    fun `near capacity keeps upstream's strict values`() {
        val expected = mapOf(
            PowerMode.PERFORMANCE to -95,
            PowerMode.BALANCED to -85,
            PowerMode.POWER_SAVER to -75,
            PowerMode.ULTRA_LOW_POWER to -65
        )
        for ((mode, dbm) in expected) {
            for (connections in 7..8) {
                assertEquals(
                    "$mode with $connections of 8",
                    ConnectionRssiThreshold.Decision(dbm, Reason.NEAR_CAPACITY),
                    resolve(mode, peers = 4, connections = connections)
                )
            }
        }
    }

    @Test
    fun `two free slots are not near capacity`() {
        assertEquals(Reason.RELAXED, resolve(PowerMode.BALANCED, peers = 3, connections = 6).reason)
    }

    @Test
    fun `the isolated and relaxed thresholds sit below phone receive sensitivity`() {
        // The trial's weakest scan was -106 dBm: nothing a phone can hear is filtered out.
        assertTrue(ConnectionRssiThreshold.ANY_AUDIBLE_DBM < -106)
    }

    private fun resolve(mode: PowerMode, peers: Int, connections: Int, max: Int = 8) =
        ConnectionRssiThreshold.resolve(mode, directPeerCount = peers, connectionCount = connections, maxConnections = max)
}
