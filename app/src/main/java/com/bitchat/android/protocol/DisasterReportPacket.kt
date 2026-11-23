package com.bitchat.android.protocol

import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToLong

/**
 * Broadcast Tier —— Health Report 中「藍牙範圍內每台裝置都能讀」的部分。
 *
 * 依 ADR-0003 的分層揭露：本結構**不攜帶姓名與聯絡方式**——沒有真實姓名、電話、血型、
 * 自由文字說明。位置是精確座標，與 Detail Tier 共用同一份（ADR-0008）：範圍內任何人都能
 * 知道 Reporter 確切在哪裡，這是為了讓人找得到而刻意接受的取捨。
 *
 * 線路格式（big-endian，最大 [MAX_ENCODED_SIZE] bytes）：
 * ```
 *   [0]        version        1 byte   VERSION；其他版本（含 geohash 的 1、2）一律拒收
 *   [1..6]     reporterHandle 6 bytes  隨機、不可反推回帳號的固定長度識別碼
 *   [7]        status         1 byte   HealthStatus.wire
 *   [8]        flags          1 byte   bit0 = SOS，bit1 = 有位置；其餘位元發送端填 0，接收端忽略
 *   [9..16]    lat, lng       2 × int32  單位 1e-7 度（[ReportLocation]）；只在 bit1 = 1 時出現
 *   [末 4]     reportTime     4 bytes  Unix 秒（unsigned，big-endian）
 * ```
 *
 * SOS 是 Health Report 上的標記，不是另一種廣播內容（ADR-0004）：帶 SOS 的回報其 Status
 * 必定是輕傷、重傷或未宣告，「未宣告」沒有 SOS、或「安全」帶 SOS 都不合法，編碼端拒絕、
 * 解碼端拒收。
 *
 * 這一份格式定義（Kotlin）與 Dart 端 `ble_packet_decoder.dart` 的 `HealthReportPayload`
 * 必須對應同一組權威向量（見 `DisasterReportTest` 與 `health_report_payload_test.dart`）。
 */
data class HealthReportPayload(
    /** 12 個十六進位字元（6 bytes）。隨機產生，不得由 Firebase UID／電話／姓名雜湊等可反推值產生。 */
    val reporterHandle: String,
    val status: HealthStatus,
    /** 精確座標；無位置資訊時為 null。 */
    val location: ReportLocation?,
    /** 回報時間（epoch millis）。線路上只保留到秒，解碼後的毫秒位固定為 0。 */
    val reportTimeMillis: Long,
    /** Reporter 是否正舉著 SOS（見 CONTEXT.md 的 SOS）。 */
    val sos: Boolean = false
) {

    fun encode(): ByteArray {
        val handleBytes = hexToBytes(reporterHandle)
        require(handleBytes.size == HANDLE_BYTES) {
            "reporterHandle 必須是 $HANDLE_BYTES bytes（$HANDLE_BYTES * 2 個 hex 字元）"
        }
        require(isLegal(status, sos)) { "Status ${status.name} 不能${if (sos) "帶" else "不帶"} SOS" }

        val size = MIN_ENCODED_SIZE + if (location != null) LOCATION_BYTES else 0
        val buffer = ByteBuffer.allocate(size).apply { order(ByteOrder.BIG_ENDIAN) }
        buffer.put(VERSION.toByte())
        buffer.put(handleBytes)
        buffer.put(status.wire)
        var flags = 0
        if (sos) flags = flags or FLAG_SOS
        if (location != null) flags = flags or FLAG_LOCATION
        buffer.put(flags.toByte())
        if (location != null) {
            buffer.putInt(location.latE7)
            buffer.putInt(location.lngE7)
        }
        buffer.putInt((reportTimeMillis / 1000L).toInt())
        return buffer.array()
    }

    companion object {
        private const val TAG = "HealthReportPayload"

        /**
         * 目前編碼的版本。[VERSION] 與 [BroadcastContentTag.HEALTH_REPORT] 是不同層的概念
         * （payload 版本 vs. 廣播內容類型），不得互相假設相等。
         *
         * 版本 3 起位置是精確座標（ADR-0008）。解碼端只接受這個版本：舊版裝置的 geohash 回報
         * 一律拒收，所有裝置要一起更新。
         */
        const val VERSION = 3

        const val HANDLE_BYTES = 6

        private const val FLAG_SOS = 0x01
        private const val FLAG_LOCATION = 0x02

        private const val LOCATION_BYTES = 8

        /** 合法的 reporterHandle 形式：HANDLE_BYTES * 2 個十六進位字元。 */
        val HANDLE_REGEX = Regex("[0-9a-fA-F]{${HANDLE_BYTES * 2}}")

        /** 沒有位置的 payload：1 + handle + status + flags + time。 */
        private const val MIN_ENCODED_SIZE = 1 + HANDLE_BYTES + 1 + 1 + 4

        /** Broadcast Tier 的位元組上界：帶位置的 payload。 */
        const val MAX_ENCODED_SIZE = MIN_ENCODED_SIZE + LOCATION_BYTES

        /** 「未宣告」只能和 SOS 一起出現；「安全」不能帶 SOS（ADR-0004）。 */
        fun isLegal(status: HealthStatus, sos: Boolean): Boolean = when (status) {
            HealthStatus.UNDECLARED -> sos
            HealthStatus.SAFE -> !sos
            HealthStatus.MINOR, HealthStatus.SEVERE -> true
        }

        /**
         * 由 Reporter 的座標建構 Broadcast Tier。[lat]、[lng] 任一為 null 時視為沒有位置；
         * 兩者都有卻不是合法的經緯度時拋 [IllegalArgumentException]。
         */
        fun fromLocation(
            reporterHandle: String,
            status: HealthStatus,
            lat: Double?,
            lng: Double?,
            reportTimeMillis: Long,
            sos: Boolean = false
        ): HealthReportPayload {
            require(HANDLE_REGEX.matches(reporterHandle)) {
                "reporterHandle 必須是 ${HANDLE_BYTES * 2} 個十六進位字元"
            }
            val location = if (lat != null && lng != null) {
                requireNotNull(ReportLocation.of(lat, lng)) { "座標不是合法的經緯度" }
            } else {
                null
            }
            return HealthReportPayload(reporterHandle.lowercase(), status, location, reportTimeMillis, sos)
        }

        /**
         * 解碼 Broadcast Tier payload。
         * 遇到未知版本、長度與 flags 不符、座標超出範圍或不合法的 Status／SOS 組合一律回傳 null
         * （拒收），不做盡力解析。日誌只輸出長度與版本號，不輸出任何欄位內容。
         */
        fun decode(data: ByteArray): HealthReportPayload? {
            try {
                if (data.size < MIN_ENCODED_SIZE) return null

                val buffer = ByteBuffer.wrap(data).apply { order(ByteOrder.BIG_ENDIAN) }

                val version = buffer.get().toInt() and 0xFF
                if (version != VERSION) {
                    Log.w(TAG, "拒收健康報告：未知 payload 版本 $version")
                    return null
                }

                val handleBytes = ByteArray(HANDLE_BYTES)
                buffer.get(handleBytes)

                val status = HealthStatus.fromWire(buffer.get()) ?: return null
                val flags = buffer.get().toInt() and 0xFF
                val sos = (flags and FLAG_SOS) != 0
                if (!isLegal(status, sos)) return null

                val hasLocation = (flags and FLAG_LOCATION) != 0
                val expectedSize = MIN_ENCODED_SIZE + if (hasLocation) LOCATION_BYTES else 0
                if (data.size != expectedSize) return null
                val location = if (hasLocation) {
                    ReportLocation.ofE7(buffer.getInt(), buffer.getInt()) ?: return null
                } else {
                    null
                }

                val reportTimeSecs = buffer.getInt().toLong() and 0xFFFFFFFFL

                return HealthReportPayload(
                    reporterHandle = bytesToHex(handleBytes),
                    status = status,
                    location = location,
                    reportTimeMillis = reportTimeSecs * 1000L,
                    sos = sos
                )
            } catch (e: Exception) {
                Log.w(TAG, "健康報告解碼失敗，長度 ${data.size}")
                return null
            }
        }

        private fun hexToBytes(hex: String): ByteArray {
            val clean = hex.trim()
            require(clean.length % 2 == 0) { "hex 長度必須為偶數" }
            return ByteArray(clean.length / 2) {
                clean.substring(it * 2, it * 2 + 2).toInt(16).toByte()
            }
        }

        private fun bytesToHex(bytes: ByteArray): String =
            bytes.joinToString("") { "%02x".format(it) }
    }
}

/**
 * Reporter 的精確座標，以線路的解析度保存：緯度、經度各一個 int32，單位 1e-7 度（約 1.1 cm）。
 * 保存的是整數，所以編碼、解碼與比對都不會因浮點數失真；互助任務以此比對後端與 mesh 上的
 * 同一份 Health Report（ADR-0010）。
 */
data class ReportLocation(val latE7: Int, val lngE7: Int) {

    val lat: Double get() = latE7 / SCALE
    val lng: Double get() = lngE7 / SCALE

    companion object {
        /** 1 度 = 10^7 個單位。Dart 端 `ReportLocation.scale` 必須相同。 */
        const val SCALE = 1e7

        private const val MAX_LAT_E7 = 900_000_000
        private const val MAX_LNG_E7 = 1_800_000_000

        /**
         * 四捨五入到 1e-7 度（0.5 往正無限大，與 `Math.round` 相同；Dart 端照同一規則）。
         * 不是合法的經緯度（NaN、無限大、超出 ±90°／±180°）時回傳 null。
         */
        fun of(lat: Double, lng: Double): ReportLocation? {
            if (!lat.isFinite() || !lng.isFinite()) return null
            if (lat < -90.0 || lat > 90.0 || lng < -180.0 || lng > 180.0) return null
            return ofE7((lat * SCALE).roundToLong().toInt(), (lng * SCALE).roundToLong().toInt())
        }

        /** 線路上的值；超出 ±90°／±180° 時回傳 null。 */
        fun ofE7(latE7: Int, lngE7: Int): ReportLocation? =
            if (latE7 in -MAX_LAT_E7..MAX_LAT_E7 && lngE7 in -MAX_LNG_E7..MAX_LNG_E7) {
                ReportLocation(latE7, lngE7)
            } else {
                null
            }
    }
}
