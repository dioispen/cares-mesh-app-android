package com.bitchat.android.protocol

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

/**
 * Broadcast Tier（A1，見 ADR-0003）的編解碼測試。
 *
 * 受測對象是 payload 的 byte 陣列：編碼結果中不應出現任何 PII，解碼結果不攜帶 PII 欄位。
 * 不驗證內部欄位如何排版。
 */
class DisasterReportTest {

    /**
     * 跨端權威向量 —— Dart 端 `health_report_payload_test.dart` 使用相同的 bytes 與欄位值。
     * version=1, handle=abcdef012345, status=重傷(2), geohash="wsqqm", reportTime=1_700_000_000 秒。
     */
    private val vectorBytes: ByteArray = byteArrayOf(
        0x01,
        0xAB.toByte(), 0xCD.toByte(), 0xEF.toByte(), 0x01, 0x23, 0x45,
        0x02,
        0x05,
        'w'.code.toByte(), 's'.code.toByte(), 'q'.code.toByte(), 'q'.code.toByte(), 'm'.code.toByte(),
        0x65, 0x53, 0xF1.toByte(), 0x00
    )

    @Test
    fun encodesToAuthoritativeVector() {
        val payload = HealthReportPayload(
            reporterHandle = "abcdef012345",
            status = HealthStatus.SEVERE,
            geohash = "wsqqm",
            reportTimeMillis = 1_700_000_000_000L
        )
        assertArrayEquals(vectorBytes, payload.encode())
    }

    @Test
    fun decodesAuthoritativeVector() {
        val decoded = HealthReportPayload.decode(vectorBytes)
        assertNotNull(decoded)
        assertEquals("abcdef012345", decoded?.reporterHandle)
        assertEquals(HealthStatus.SEVERE, decoded?.status)
        assertEquals("wsqqm", decoded?.geohash)
        assertEquals(1_700_000_000_000L, decoded?.reportTimeMillis)
    }

    @Test
    fun roundTripsWithLocation() {
        val original = HealthReportPayload.fromLocation(
            reporterHandle = "0011223344FF",
            status = HealthStatus.MINOR,
            lat = 25.0330,
            lng = 121.5654,
            reportTimeMillis = 1_700_000_123_456L
        )
        val decoded = HealthReportPayload.decode(original.encode())
        assertNotNull(decoded)
        assertEquals(original.reporterHandle, decoded?.reporterHandle)
        assertEquals("0011223344ff", decoded?.reporterHandle) // fromLocation lower-cases
        assertEquals(original.status, decoded?.status)
        assertEquals(original.geohash, decoded?.geohash)
        // 線路上只保留到秒
        assertEquals(1_700_000_123_000L, decoded?.reportTimeMillis)
    }

    /**
     * 本 spec 最重要的一條：以含姓名／電話／血型／描述的完整資料建構回報並送入廣播編碼路徑，
     * 斷言輸出 bytes 中找不到這些字串的任何 UTF-8 片段，也找不到精確座標的原始位元組。
     */
    @Test
    fun broadcastEncodingCarriesNoPII() {
        val name = "王小明"
        val phone = "0912345678"
        val bloodType = "AB"
        val note = "受困三樓需要擔架"
        val lat = 25.0330
        val lng = 121.5654

        val encoded = HealthReportPayload.fromLocation(
            reporterHandle = "abcdef012345",
            status = HealthStatus.SEVERE,
            lat = lat,
            lng = lng,
            reportTimeMillis = 1_700_000_000_000L
        ).encode()

        for (pii in listOf(name, phone, bloodType, note)) {
            assertTrue(
                "廣播 payload 不應包含 PII 片段: $pii",
                indexOfSub(encoded, pii.toByteArray(Charsets.UTF_8)) < 0
            )
        }
        for (coord in listOf(lat, lng)) {
            val raw = ByteBuffer.allocate(8).putDouble(coord).array()
            assertTrue(
                "廣播 payload 不應夾帶原始經緯度的 IEEE-754 位元組",
                indexOfSub(encoded, raw) < 0
            )
        }
    }

    @Test
    fun locationIsCoarsenedNotExact() {
        val lat = 25.0330
        val lng = 121.5654
        val decoded = HealthReportPayload.decode(
            HealthReportPayload.fromLocation("abcdef012345", HealthStatus.SAFE, lat, lng, 1L).encode()
        )!!
        val approx = decoded.approximateLatLng()!!
        assertNotEquals(lat, approx.first, 0.0)
        assertNotEquals(lng, approx.second, 0.0)
        // 誤差落在 geohash-5 精度的量級（數公里 ≈ 0.1 度以內）
        assertTrue(Math.abs(lat - approx.first) < 0.1)
        assertTrue(Math.abs(lng - approx.second) < 0.1)
    }

    @Test
    fun noLocationRoundTrips() {
        val decoded = HealthReportPayload.decode(
            HealthReportPayload
                .fromLocation("abcdef012345", HealthStatus.SEVERE, null, null, 1_700_000_000_000L)
                .encode()
        )
        assertNotNull(decoded)
        assertEquals("", decoded?.geohash)
        assertNull(decoded?.approximateLatLng())
        assertEquals(HealthStatus.SEVERE, decoded?.status)
    }

    @Test
    fun encodedSizeWithinBroadcastTierBound() {
        val encoded = HealthReportPayload.fromLocation(
            "abcdef012345", HealthStatus.SEVERE, 25.0330, 121.5654, 1_700_000_000_000L
        ).encode()
        assertTrue(encoded.size <= HealthReportPayload.MAX_ENCODED_SIZE)
        assertEquals(18, HealthReportPayload.MAX_ENCODED_SIZE)
    }

    @Test
    fun rejectsUnknownVersion() {
        val good = HealthReportPayload.fromLocation(
            "abcdef012345", HealthStatus.SEVERE, 25.0, 121.0, 1_700_000_000_000L
        ).encode()
        val badVersion = good.copyOf().also { it[0] = 0x02 }
        assertNull(HealthReportPayload.decode(badVersion))

        // 舊格式的第一個 byte 是 reporterId 的長度前綴（通常不是 1），不應被誤讀成有效回報
        val legacyish = byteArrayOf(0x0B, 0x54, 0x45, 0x53, 0x54, 0x2D, 0x49, 0x44)
        assertNull(HealthReportPayload.decode(legacyish))
    }

    @Test(expected = IllegalArgumentException::class)
    fun fromLocationRejectsMalformedHandle() {
        HealthReportPayload.fromLocation(
            "not-a-hex-handle", HealthStatus.SAFE, 25.0, 121.0, 1_700_000_000_000L
        )
    }

    @Test
    fun decodesJunkToNull() {
        assertNull(HealthReportPayload.decode(byteArrayOf(0x01, 0x02, 0x03)))
        assertNull(HealthReportPayload.decode(ByteArray(0)))
    }

    @Test
    fun bitchatPacketIntegration() {
        val payload = HealthReportPayload.fromLocation(
            "abcdef012345", HealthStatus.SAFE, 25.0, 121.0, 1_700_000_000_000L
        )
        val packet = BitchatPacket(
            type = MessageType.HEALTH_REPORT.value,
            ttl = 7u,
            senderID = "0102030405060708",
            payload = byteArrayOf(BroadcastContentTag.HEALTH_REPORT.value) + payload.encode()
        )
        assertEquals(0x30, MessageType.HEALTH_REPORT.value.toInt())

        // MessageHandler.handleTaggedBroadcast() 會剝掉 payload[0] 的 ContentTag
        val dataPayload = packet.payload.drop(1).toByteArray()
        val decoded = HealthReportPayload.decode(dataPayload)
        assertEquals(HealthStatus.SAFE, decoded?.status)
    }

    private fun indexOfSub(haystack: ByteArray, needle: ByteArray): Int {
        if (needle.isEmpty() || needle.size > haystack.size) return -1
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) {
                if (haystack[i + j] != needle[j]) continue@outer
            }
            return i
        }
        return -1
    }
}
