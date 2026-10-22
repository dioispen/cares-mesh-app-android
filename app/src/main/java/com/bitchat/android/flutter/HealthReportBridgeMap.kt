package com.bitchat.android.flutter

import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus

/**
 * Flutter `BitchatBridge.sendHealthReport` 傳來的 map → Broadcast Tier payload。
 *
 * 只讀不具識別性的欄位——`reporterHandle`、`status`（中文 label）、原始 `lat`/`lng`
 * （在此就地降精度為 geohash，精確值不會進入廣播封包）與 `sos`（缺少時視為沒有 SOS）。
 * 任何 PII（姓名、電話、血型、自由文字）即使出現在 map 中也一律忽略。
 */
object HealthReportBridgeMap {

    /** 欄位缺少、型別不對、或 Status 與 SOS 的組合不合法（ADR-0004）時回傳 null。 */
    fun toPayload(map: Map<*, *>, reportTimeMillis: Long): HealthReportPayload? {
        val handle = map["reporterHandle"] as? String ?: return null
        if (!HealthReportPayload.HANDLE_REGEX.matches(handle)) return null
        val status = HealthStatus.fromLabel(map["status"] as? String ?: return null) ?: return null
        val sos = when (val raw = map["sos"]) {
            null -> false
            is Boolean -> raw
            else -> return null
        }
        if (!HealthReportPayload.isLegal(status, sos)) return null
        return HealthReportPayload.fromLocation(
            reporterHandle = handle,
            status = status,
            lat = (map["lat"] as? Number)?.toDouble(),
            lng = (map["lng"] as? Number)?.toDouble(),
            reportTimeMillis = reportTimeMillis,
            sos = sos
        )
    }
}
