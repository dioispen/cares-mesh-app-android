package com.bitchat.android.flutter

import com.bitchat.android.protocol.HealthStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The map Flutter's `BitchatBridge.sendHealthReport` hands over, turned into a Broadcast Tier. */
class HealthReportBridgeMapTest {

    private val base = mapOf<String, Any?>(
        "reporterHandle" to "abcdef012345",
        "status" to "重傷",
        "lat" to 25.0330,
        "lng" to 121.5654
    )

    @Test
    fun `carries the SOS mark`() {
        val payload = HealthReportBridgeMap.toPayload(base + ("sos" to true), 1_700_000_000_000L)

        assertEquals(true, payload?.sos)
        assertEquals(HealthStatus.SEVERE, payload?.status)
        assertEquals(5, payload?.geohash?.length)
        assertEquals(1_700_000_000_000L, payload?.reportTimeMillis)
    }

    @Test
    fun `a missing sos field means no SOS`() {
        assertEquals(false, HealthReportBridgeMap.toPayload(base, 1L)?.sos)
        assertEquals(false, HealthReportBridgeMap.toPayload(base + ("sos" to false), 1L)?.sos)
    }

    @Test
    fun `未宣告 with SOS and no location`() {
        val payload = HealthReportBridgeMap.toPayload(
            mapOf("reporterHandle" to "abcdef012345", "status" to "未宣告", "sos" to true),
            1L
        )

        assertEquals(HealthStatus.UNDECLARED, payload?.status)
        assertEquals(true, payload?.sos)
        assertEquals("", payload?.geohash)
    }

    @Test
    fun `an illegal Status and SOS combination is refused`() {
        assertNull(HealthReportBridgeMap.toPayload(base + ("status" to "未宣告"), 1L))
        assertNull(HealthReportBridgeMap.toPayload(base + ("status" to "安全") + ("sos" to true), 1L))
    }

    @Test
    fun `a malformed map is refused`() {
        assertNull(HealthReportBridgeMap.toPayload(base + ("reporterHandle" to "nope"), 1L))
        assertNull(HealthReportBridgeMap.toPayload(base + ("status" to "unknown"), 1L))
        assertNull(HealthReportBridgeMap.toPayload(base - "status", 1L))
        assertNull(HealthReportBridgeMap.toPayload(base + ("sos" to "yes"), 1L))
    }
}
