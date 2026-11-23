package com.bitchat.android.flutter

import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.protocol.ReportLocation

/**
 * Flutter `BitchatBridge.sendHealthReport` 傳來的 map → Broadcast Tier payload。
 *
 * 只讀 Broadcast Tier 的欄位——`reporterHandle`、`status`（中文 label）、`lat`/`lng`（精確座標，
 * 與 Detail Tier 是同一份，ADR-0008）、`reportTimeMs` 與 `sos`（缺少時視為沒有 SOS）。任何 PII
 * （姓名、電話、血型、自由文字）即使出現在 map 中也一律忽略。
 *
 * `reportTimeMs` 是 Flutter 寫進後端的同一個回報時間，不是原生端送出的時間：互助任務以座標與
 * `reportTime` 比對後端與 mesh 上的同一份 Health Report（ADR-0010），兩邊差一秒就對不上。
 */
object HealthReportBridgeMap {

    /** 欄位缺少、型別不對、座標不合法，或 Status 與 SOS 的組合不合法（ADR-0004）時回傳 null。 */
    fun toPayload(map: Map<*, *>): HealthReportPayload? {
        val handle = map["reporterHandle"] as? String ?: return null
        if (!HealthReportPayload.HANDLE_REGEX.matches(handle)) return null
        val status = HealthStatus.fromLabel(map["status"] as? String ?: return null) ?: return null
        val sos = when (val raw = map["sos"]) {
            null -> false
            is Boolean -> raw
            else -> return null
        }
        if (!HealthReportPayload.isLegal(status, sos)) return null
        val reportTimeMillis = (map["reportTimeMs"] as? Number)?.toLong() ?: return null
        if (reportTimeMillis < 0) return null
        val lat = (map["lat"] as? Number)?.toDouble()
        val lng = (map["lng"] as? Number)?.toDouble()
        if (lat != null && lng != null && ReportLocation.of(lat, lng) == null) return null
        return HealthReportPayload.fromLocation(
            reporterHandle = handle,
            status = status,
            lat = lat,
            lng = lng,
            reportTimeMillis = reportTimeMillis,
            sos = sos
        )
    }
}
