package com.bitchat.android.protocol

/**
 * Status —— Reporter 自我宣告的身體狀況。
 *
 * 這個 enum 是 Status ↔ 線路位元組對應的**單一真相來源**（見 ADR-0002、ADR-0003）。
 * 中文字串（安全／輕傷／重傷）只存在於 UI 與 Firestore 查詢鍵，永遠不上 BLE 線路；
 * 線路上一律是 [wire] 這個單一位元組，不受在地化字串影響。
 */
enum class HealthStatus(val wire: Byte, val label: String) {
    SAFE(0, "安全"),
    MINOR(1, "輕傷"),
    SEVERE(2, "重傷");

    companion object {
        fun fromWire(b: Byte): HealthStatus? = values().find { it.wire == b }
        fun fromLabel(label: String): HealthStatus? = values().find { it.label == label }
    }
}
