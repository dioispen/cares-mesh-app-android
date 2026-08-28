package com.bitchat.android.protocol

import android.util.Log
import com.bitchat.android.geohash.Geohash
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Broadcast Tier —— Health Report 中「藍牙範圍內每台裝置都能讀」的部分。
 *
 * 依 ADR-0003 的分層揭露：本結構**不攜帶任何可識別個人的欄位**——沒有真實姓名、
 * 電話、血型、自由文字說明，也沒有公尺級座標。真實身分與精確座標屬於 Detail Tier，
 * 不走廣播，僅在 Rescuer 透過既有 Noise session 提出請求時釋出（A2，另開 issue）。
 *
 * 線路格式（big-endian，最大 [MAX_ENCODED_SIZE] bytes）：
 * ```
 *   [0]        version        1 byte   目前為 VERSION；未知版本一律拒收，不做盡力解析
 *   [1..6]     reporterHandle 6 bytes  不具識別性、不可反推回帳號的固定長度識別碼
 *   [7]        status         1 byte   HealthStatus.wire
 *   [8]        geohashLen     1 byte   0 或 GEOHASH_PRECISION
 *   [9..]      geohash        geohashLen bytes  ASCII base32，降精度近似位置
 *   [末 4]     reportTime     4 bytes  Unix 秒（unsigned，big-endian）
 * ```
 *
 * 這一份格式定義（Kotlin）與 Dart 端 `ble_packet_decoder.dart` 的 `HealthReportPayload`
 * 必須對應同一組權威向量（見 `DisasterReportTest` 與 `health_report_payload_test.dart`）。
 */
data class HealthReportPayload(
    /** 12 個十六進位字元（6 bytes）。不具識別性，不得由 Firebase UID／電話／姓名雜湊等可反推值產生。 */
    val reporterHandle: String,
    val status: HealthStatus,
    /** 降精度 geohash；無位置資訊時為空字串。 */
    val geohash: String,
    /** 回報時間（epoch millis）。線路上只保留到秒，解碼後的毫秒位固定為 0。 */
    val reportTimeMillis: Long
) {

    fun encode(): ByteArray {
        val handleBytes = hexToBytes(reporterHandle)
        require(handleBytes.size == HANDLE_BYTES) {
            "reporterHandle 必須是 $HANDLE_BYTES bytes（$HANDLE_BYTES * 2 個 hex 字元）"
        }
        val ghBytes = geohash.toByteArray(Charsets.US_ASCII)
        require(ghBytes.isEmpty() || ghBytes.size == GEOHASH_PRECISION) {
            "geohash 長度必須為 0 或 $GEOHASH_PRECISION"
        }

        val size = 1 + HANDLE_BYTES + 1 + 1 + ghBytes.size + 4
        val buffer = ByteBuffer.allocate(size).apply { order(ByteOrder.BIG_ENDIAN) }
        buffer.put(VERSION.toByte())
        buffer.put(handleBytes)
        buffer.put(status.wire)
        buffer.put(ghBytes.size.toByte())
        buffer.put(ghBytes)
        buffer.putInt((reportTimeMillis / 1000L).toInt())
        return buffer.array()
    }

    /** 由 geohash 還原的近似中心座標；無位置時為 null。這是「大約在哪」而非確切位置。 */
    fun approximateLatLng(): Pair<Double, Double>? =
        if (geohash.isEmpty()) null else Geohash.decodeToCenter(geohash)

    companion object {
        private const val TAG = "HealthReportPayload"

        const val VERSION = 1
        const val HANDLE_BYTES = 6

        /**
         * 合法的 reporterHandle 形式：HANDLE_BYTES * 2 個十六進位字元。
         * 注意 [VERSION] 與 [BroadcastContentTag.HEALTH_REPORT] 的數值目前都是 1，
         * 但兩者是不同層的概念（payload 版本 vs. 廣播內容類型），不得互相假設相等。
         */
        val HANDLE_REGEX = Regex("[0-9a-fA-F]{${HANDLE_BYTES * 2}}")

        /**
         * Broadcast Tier 的「隱私半徑」單一決策點。
         * geohash-5 ≈ 數公里見方——足以做檢傷排序，不足以定位到 Reporter 本人。
         */
        const val GEOHASH_PRECISION = 5

        /** Broadcast Tier 的位元組上界：1 + handle + status + geohashLen + geohash + time。 */
        const val MAX_ENCODED_SIZE = 1 + HANDLE_BYTES + 1 + 1 + GEOHASH_PRECISION + 4

        private const val MIN_ENCODED_SIZE = 1 + HANDLE_BYTES + 1 + 1 + 4

        /**
         * 由完整資料建構 Broadcast Tier：座標在此就地降精度為 geohash，
         * 精確經緯度不進入回傳物件，也不會出現在 [encode] 的輸出中。
         */
        fun fromLocation(
            reporterHandle: String,
            status: HealthStatus,
            lat: Double?,
            lng: Double?,
            reportTimeMillis: Long
        ): HealthReportPayload {
            require(HANDLE_REGEX.matches(reporterHandle)) {
                "reporterHandle 必須是 ${HANDLE_BYTES * 2} 個十六進位字元"
            }
            val gh = if (lat != null && lng != null) {
                Geohash.encode(lat, lng, GEOHASH_PRECISION)
            } else {
                ""
            }
            return HealthReportPayload(reporterHandle.lowercase(), status, gh, reportTimeMillis)
        }

        /**
         * 解碼 Broadcast Tier payload。
         * 遇到未知版本或格式不符一律回傳 null（拒收），不做盡力解析。
         * 日誌只輸出長度與版本號，不輸出任何欄位內容。
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

                val ghLen = buffer.get().toInt() and 0xFF
                if (ghLen != 0 && ghLen != GEOHASH_PRECISION) return null
                if (buffer.remaining() < ghLen + 4) return null
                val ghBytes = ByteArray(ghLen)
                buffer.get(ghBytes)
                val geohash = String(ghBytes, Charsets.US_ASCII)

                val reportTimeSecs = buffer.getInt().toLong() and 0xFFFFFFFFL

                return HealthReportPayload(
                    reporterHandle = bytesToHex(handleBytes),
                    status = status,
                    geohash = geohash,
                    reportTimeMillis = reportTimeSecs * 1000L
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
