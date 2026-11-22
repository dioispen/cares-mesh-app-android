package com.bitchat.android.protocol

import org.junit.Assert.*
import org.junit.Test

/**
 * Broadcast Tier（ADR-0003、ADR-0008）的編解碼測試。
 *
 * 受測對象是 payload 的 byte 陣列：編碼結果不帶姓名與聯絡方式，位置是精確座標。
 */
class DisasterReportTest {

    /**
     * 跨端權威向量 —— Dart 端 `health_report_payload_test.dart` 使用相同的 bytes 與欄位值。
     * version=3, handle=abcdef012345, status=重傷(2), flags=SOS|有位置,
     * lat=25.0330000（250330000）, lng=121.5654000（1215654000）, reportTime=1_700_000_000 秒。
     */
    private val vectorBytes: ByteArray = byteArrayOf(
        0x03,
        0xAB.toByte(), 0xCD.toByte(), 0xEF.toByte(), 0x01, 0x23, 0x45,
        0x02,
        0x03,
        0x0E, 0xEB.toByte(), 0xBB.toByte(), 0x90.toByte(),
        0x48, 0x75, 0x68, 0x70,
        0x65, 0x53, 0xF1.toByte(), 0x00
    )

    /** 同上但沒有 SOS：flags 只剩「有位置」。 */
    private val vectorNoSosBytes: ByteArray = vectorBytes.copyOf().also { it[8] = 0x02 }

    /** version=3, status=未宣告(3), flags=SOS, 沒有位置。 */
    private val vectorUndeclaredSosBytes: ByteArray = byteArrayOf(
        0x03,
        0xAB.toByte(), 0xCD.toByte(), 0xEF.toByte(), 0x01, 0x23, 0x45,
        0x03,
        0x01,
        0x65, 0x53, 0xF1.toByte(), 0x00
    )

    /** 負的經緯度（南半球、西半球），鎖住 int32 的正負號：status=輕傷(1), lat=-33.8688, lng=-151.2093。 */
    private val vectorNegativeBytes: ByteArray = byteArrayOf(
        0x03,
        0xAB.toByte(), 0xCD.toByte(), 0xEF.toByte(), 0x01, 0x23, 0x45,
        0x01,
        0x02,
        0xEB.toByte(), 0xD0.toByte(), 0x08, 0x00,
        0xA5.toByte(), 0xDF.toByte(), 0x4A, 0xB8.toByte(),
        0x65, 0x53, 0xF1.toByte(), 0x00
    )

    private val taipei = ReportLocation(250_330_000, 1_215_654_000)

    @Test
    fun encodesToAuthoritativeVector() {
        val payload = HealthReportPayload(
            reporterHandle = "abcdef012345",
            status = HealthStatus.SEVERE,
            location = taipei,
            reportTimeMillis = 1_700_000_000_000L,
            sos = true
        )
        assertArrayEquals(vectorBytes, payload.encode())
    }

    @Test
    fun decodesAuthoritativeVector() {
        val decoded = HealthReportPayload.decode(vectorBytes)
        assertNotNull(decoded)
        assertEquals("abcdef012345", decoded?.reporterHandle)
        assertEquals(HealthStatus.SEVERE, decoded?.status)
        assertEquals(true, decoded?.sos)
        assertEquals(taipei, decoded?.location)
        assertEquals(25.0330, decoded!!.location!!.lat, 0.0)
        assertEquals(121.5654, decoded.location!!.lng, 0.0)
        assertEquals(1_700_000_000_000L, decoded.reportTimeMillis)
    }

    @Test
    fun negativeCoordinatesKeepTheirSign() {
        val location = ReportLocation(-338_688_000, -1_512_093_000)
        val payload = HealthReportPayload("abcdef012345", HealthStatus.MINOR, location, 1_700_000_000_000L)
        assertArrayEquals(vectorNegativeBytes, payload.encode())

        val decoded = HealthReportPayload.decode(vectorNegativeBytes)!!
        assertEquals(location, decoded.location)
        assertEquals(-33.8688, decoded.location!!.lat, 0.0)
        assertEquals(-151.2093, decoded.location!!.lng, 0.0)
    }

    @Test
    fun withoutSosOnlyTheLocationFlagIsSet() {
        val payload = HealthReportPayload("abcdef012345", HealthStatus.SEVERE, taipei, 1_700_000_000_000L)
        assertArrayEquals(vectorNoSosBytes, payload.encode())
        assertEquals(false, HealthReportPayload.decode(vectorNoSosBytes)?.sos)
    }

    @Test
    fun undeclaredStatusWithSosAndNoLocation() {
        val payload = HealthReportPayload(
            "abcdef012345", HealthStatus.UNDECLARED, null, 1_700_000_000_000L, sos = true
        )
        assertArrayEquals(vectorUndeclaredSosBytes, payload.encode())

        val decoded = HealthReportPayload.decode(vectorUndeclaredSosBytes)
        assertEquals(HealthStatus.UNDECLARED, decoded?.status)
        assertEquals(true, decoded?.sos)
        assertNull(decoded?.location)
    }

    /** flags 其餘位元保留給以後：接收端忽略，只看 bit0 與 bit1。 */
    @Test
    fun ignoresReservedFlagBits() {
        val reserved = vectorBytes.copyOf().also { it[8] = 0xFF.toByte() }
        assertEquals(true, HealthReportPayload.decode(reserved)?.sos)
        assertEquals(taipei, HealthReportPayload.decode(reserved)?.location)
        val reservedNoSos = vectorBytes.copyOf().also { it[8] = 0xFE.toByte() }
        assertEquals(false, HealthReportPayload.decode(reservedNoSos)?.sos)
        val reservedNoLocation = vectorUndeclaredSosBytes.copyOf().also { it[8] = 0xFD.toByte() }
        assertNull(HealthReportPayload.decode(reservedNoLocation)?.location)
    }

    /** 「未宣告」只能和 SOS 一起出現；「安全」不能帶 SOS（ADR-0004）。 */
    @Test
    fun rejectsIllegalStatusAndSosCombinations() {
        val undeclaredWithoutSos = vectorUndeclaredSosBytes.copyOf().also { it[8] = 0x00 }
        assertNull(HealthReportPayload.decode(undeclaredWithoutSos))

        val safeWithSos = vectorBytes.copyOf().also { it[7] = 0x00 }
        assertNull(HealthReportPayload.decode(safeWithSos))
    }

    @Test(expected = IllegalArgumentException::class)
    fun encodeRejectsUndeclaredWithoutSos() {
        HealthReportPayload("abcdef012345", HealthStatus.UNDECLARED, null, 1L).encode()
    }

    @Test(expected = IllegalArgumentException::class)
    fun encodeRejectsSafeWithSos() {
        HealthReportPayload("abcdef012345", HealthStatus.SAFE, null, 1L, sos = true).encode()
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
        assertEquals("0011223344ff", decoded?.reporterHandle) // fromLocation lower-cases
        assertEquals(original.status, decoded?.status)
        assertEquals(taipei, decoded?.location)
        // 線路上只保留到秒
        assertEquals(1_700_000_123_000L, decoded?.reportTimeMillis)
    }

    /** 不再降精度（ADR-0008）：解碼後的座標與 Reporter 送出的相差不到 1e-7 度的一半。 */
    @Test
    fun locationIsPreciseNotCoarsened() {
        val lat = 25.03312345
        val lng = 121.56543219
        val decoded = HealthReportPayload.decode(
            HealthReportPayload.fromLocation("abcdef012345", HealthStatus.SAFE, lat, lng, 1L).encode()
        )!!
        assertEquals(lat, decoded.location!!.lat, 0.5e-7)
        assertEquals(lng, decoded.location!!.lng, 0.5e-7)
    }

    /** 四捨五入到 1e-7 度。Dart 端以同一規則換算後端的座標來比對（ADR-0010）。 */
    @Test
    fun coordinatesRoundToTheNearestTenMillionthOfADegree() {
        assertEquals(ReportLocation(250_330_000, 1_215_654_000), ReportLocation.of(25.03300004, 121.56540004))
        assertEquals(ReportLocation(250_330_001, 1_215_654_001), ReportLocation.of(25.03300006, 121.56540006))
        assertEquals(ReportLocation(-250_330_000, -1_215_654_000), ReportLocation.of(-25.03300004, -121.56540004))
        assertEquals(ReportLocation(-250_330_001, -1_215_654_001), ReportLocation.of(-25.03300006, -121.56540006))
    }

    @Test
    fun theEdgesOfTheGlobeAreLegal() {
        val corner = ReportLocation.of(-90.0, 180.0)!!
        assertEquals(ReportLocation(-900_000_000, 1_800_000_000), corner)
        val decoded = HealthReportPayload.decode(
            HealthReportPayload("abcdef012345", HealthStatus.SAFE, corner, 1L).encode()
        )
        assertEquals(corner, decoded?.location)
    }

    @Test
    fun invalidCoordinatesAreNotALocation() {
        for ((lat, lng) in listOf(
            90.0000001 to 0.0, -90.0000001 to 0.0, 0.0 to 180.0000001, 0.0 to -180.0000001,
            Double.NaN to 0.0, 0.0 to Double.POSITIVE_INFINITY
        )) {
            assertNull("$lat, $lng", ReportLocation.of(lat, lng))
        }
        assertNull(ReportLocation.ofE7(900_000_001, 0))
        assertNull(ReportLocation.ofE7(0, -1_800_000_001))
    }

    @Test(expected = IllegalArgumentException::class)
    fun fromLocationRejectsAnInvalidCoordinate() {
        HealthReportPayload.fromLocation("abcdef012345", HealthStatus.SAFE, 91.0, 121.0, 1L)
    }

    @Test
    fun decodeRejectsCoordinatesOutsideTheGlobe() {
        val latTooFar = vectorBytes.copyOf().also {
            // 900_000_001 = 0x35A4E901
            it[9] = 0x35; it[10] = 0xA4.toByte(); it[11] = 0xE9.toByte(); it[12] = 0x01
        }
        assertNull(HealthReportPayload.decode(latTooFar))
        val lngTooFar = vectorBytes.copyOf().also {
            // -1_800_000_001 = 0x94B62DFF
            it[13] = 0x94.toByte(); it[14] = 0xB6.toByte(); it[15] = 0x2D; it[16] = 0xFF.toByte()
        }
        assertNull(HealthReportPayload.decode(lngTooFar))
    }

    /** 長度必須與 flags 相符：有位置就是 21 bytes，沒有就是 13 bytes，多一個 byte 也不收。 */
    @Test
    fun rejectsALengthThatDisagreesWithTheFlags() {
        assertNull(HealthReportPayload.decode(vectorUndeclaredSosBytes.copyOf().also { it[8] = 0x03 }))
        assertNull(HealthReportPayload.decode(vectorBytes.copyOf().also { it[8] = 0x01 }))
        assertNull(HealthReportPayload.decode(vectorBytes + byteArrayOf(0x00)))
        assertNull(HealthReportPayload.decode(vectorUndeclaredSosBytes + byteArrayOf(0x00)))
        assertNull(HealthReportPayload.decode(vectorBytes.copyOf(vectorBytes.size - 1)))
    }

    /** 舊版裝置的 geohash 回報（版本 1、2）一律拒收：所有裝置一起更新，不混用（ADR-0008）。 */
    @Test
    fun rejectsTheGeohashVersions() {
        val geohash = "wsqqqm".toByteArray(Charsets.US_ASCII)
        val handle = byteArrayOf(0xAB.toByte(), 0xCD.toByte(), 0xEF.toByte(), 0x01, 0x23, 0x45)
        val time = byteArrayOf(0x65, 0x53, 0xF1.toByte(), 0x00)
        val v2 = byteArrayOf(0x02) + handle + byteArrayOf(0x02, 0x01, 0x06) + geohash + time
        val v2NoLocation = byteArrayOf(0x02) + handle + byteArrayOf(0x03, 0x01, 0x00) + time
        val v1 = byteArrayOf(0x01) + handle + byteArrayOf(0x02, 0x06) + geohash + time
        assertNull(HealthReportPayload.decode(v2))
        assertNull(HealthReportPayload.decode(v2NoLocation))
        assertNull(HealthReportPayload.decode(v1))
    }

    @Test
    fun noLocationRoundTrips() {
        for ((lat, lng) in listOf(null to null, 25.0 to null, null to 121.0)) {
            val decoded = HealthReportPayload.decode(
                HealthReportPayload
                    .fromLocation("abcdef012345", HealthStatus.SEVERE, lat, lng, 1_700_000_000_000L)
                    .encode()
            )
            assertNotNull(decoded)
            assertNull("$lat, $lng", decoded?.location)
            assertEquals(HealthStatus.SEVERE, decoded?.status)
        }
    }

    @Test
    fun encodedSizeWithinBroadcastTierBound() {
        val withLocation = HealthReportPayload.fromLocation(
            "abcdef012345", HealthStatus.SEVERE, 25.0330, 121.5654, 1_700_000_000_000L
        ).encode()
        val withoutLocation = HealthReportPayload.fromLocation(
            "abcdef012345", HealthStatus.SEVERE, null, null, 1_700_000_000_000L
        ).encode()
        // 1 + 6 + 1 + 1 + 8 + 4：上界由 20 增為 21；沒有位置時由 14 減為 13（ADR-0008）
        assertEquals(21, HealthReportPayload.MAX_ENCODED_SIZE)
        assertEquals(21, withLocation.size)
        assertEquals(21, vectorBytes.size)
        assertEquals(13, withoutLocation.size)
    }

    @Test
    fun rejectsUnknownVersion() {
        for (version in listOf(0x00, 0x02, 0x04, 0xFF)) {
            assertNull(HealthReportPayload.decode(vectorBytes.copyOf().also { it[0] = version.toByte() }))
        }

        // 最早的格式第一個 byte 是 reporterId 的長度前綴，不應被誤讀成有效回報
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
        assertNull(HealthReportPayload.decode(byteArrayOf(0x03, 0x02, 0x03)))
        assertNull(HealthReportPayload.decode(ByteArray(0)))
    }

    /** 姓名、電話、血型與自由文字屬於 Detail／Sensitive Tier，不進廣播（ADR-0003）。 */
    @Test
    fun broadcastEncodingCarriesNoNameOrContactDetails() {
        val encoded = HealthReportPayload.fromLocation(
            reporterHandle = "abcdef012345",
            status = HealthStatus.SEVERE,
            lat = 25.0330,
            lng = 121.5654,
            reportTimeMillis = 1_700_000_000_000L
        ).encode()

        for (pii in listOf("王小明", "0912345678", "AB", "受困三樓需要擔架")) {
            assertTrue(
                "廣播 payload 不應包含 PII 片段: $pii",
                indexOfSub(encoded, pii.toByteArray(Charsets.UTF_8)) < 0
            )
        }
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
        assertEquals(ReportLocation(250_000_000, 1_210_000_000), decoded?.location)
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
