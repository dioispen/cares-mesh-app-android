package com.bitchat.android.flutter

import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.protocol.ReportLocation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The map Flutter's `BitchatBridge.sendHealthReport` hands over, turned into a Broadcast Tier. */
class HealthReportBridgeMapTest {

    private val base = mapOf<String, Any?>(
        "reporterHandle" to "abcdef012345",
        "status" to "重傷",
        "lat" to 25.0330,
        "lng" to 121.5654,
        "reportTimeMs" to 1_700_000_000_123L
    )

    @Test
    fun `carries the SOS mark, the precise location and Flutter's reportTime`() {
        val payload = HealthReportBridgeMap.toPayload(base + ("sos" to true))

        assertEquals(true, payload?.sos)
        assertEquals(HealthStatus.SEVERE, payload?.status)
        // 精確座標，不再降精度（ADR-0008）
        assertEquals(ReportLocation(250_330_000, 1_215_654_000), payload?.location)
        // 後端寫的是同一個時間，互助任務才對得起來（ADR-0010）
        assertEquals(1_700_000_000_123L, payload?.reportTimeMillis)
    }

    @Test
    fun `a reportTime small enough to arrive as an Int is read too`() {
        assertEquals(1_000L, HealthReportBridgeMap.toPayload(base + ("reportTimeMs" to 1_000))?.reportTimeMillis)
    }

    @Test
    fun `a missing sos field means no SOS`() {
        assertEquals(false, HealthReportBridgeMap.toPayload(base)?.sos)
        assertEquals(false, HealthReportBridgeMap.toPayload(base + ("sos" to false))?.sos)
    }

    @Test
    fun `未宣告 with SOS and no location`() {
        val payload = HealthReportBridgeMap.toPayload(
            mapOf("reporterHandle" to "abcdef012345", "status" to "未宣告", "sos" to true, "reportTimeMs" to 1L)
        )

        assertEquals(HealthStatus.UNDECLARED, payload?.status)
        assertEquals(true, payload?.sos)
        assertNull(payload?.location)
    }

    @Test
    fun `an illegal Status and SOS combination is refused`() {
        assertNull(HealthReportBridgeMap.toPayload(base + ("status" to "未宣告")))
        assertNull(HealthReportBridgeMap.toPayload(base + ("status" to "安全") + ("sos" to true)))
    }

    @Test
    fun `a coordinate outside the globe is refused, not dropped`() {
        assertNull(HealthReportBridgeMap.toPayload(base + ("lat" to 91.0)))
        assertNull(HealthReportBridgeMap.toPayload(base + ("lng" to Double.NaN)))
    }

    @Test
    fun `a malformed map is refused`() {
        assertNull(HealthReportBridgeMap.toPayload(base + ("reporterHandle" to "nope")))
        assertNull(HealthReportBridgeMap.toPayload(base + ("status" to "unknown")))
        assertNull(HealthReportBridgeMap.toPayload(base - "status"))
        assertNull(HealthReportBridgeMap.toPayload(base + ("sos" to "yes")))
        assertNull(HealthReportBridgeMap.toPayload(base - "reportTimeMs"))
        assertNull(HealthReportBridgeMap.toPayload(base + ("reportTimeMs" to "1700000000000")))
        assertNull(HealthReportBridgeMap.toPayload(base + ("reportTimeMs" to -1L)))
    }
}
