package com.bitchat.android.experiment

import java.util.Locale

/**
 * `exp.csv` 的一列（#70）。欄位順序即 [CSV_HEADER]；沒有值的欄位留空。
 *
 * `(src, pts)` 唯一識別一個封包：[src] 是封包 senderID 的前 8 個 hex 字元，[pts] 是封包標頭的
 * timestamp（發送端時鐘，ms），發送端的 `TX` 與接收端的 `RX` 以它對齊。
 */
data class ExperimentEvent(
    /** 事件發生時本機的 `System.currentTimeMillis()`。 */
    val tMs: Long,
    val ev: Kind,
    /** MessageType 數值，輸出為 `0x30` 形式。 */
    val type: Int? = null,
    val src: String? = null,
    val pts: Long? = null,
    /** 收到或送出時的 TTL。 */
    val ttl: Int? = null,
    /** 線路上的封包長度（bytes）。 */
    val len: Int? = null,
    /** `RX`／`DUP`／`QFULL`：那條鏈路的 peerID 前 8 碼；`LINK_*`／`STAT`：鄰居 peerID 前 8 碼。 */
    val peer: String? = null,
    /** `TX`／`RELAY`：實際寫出的鏈路數。 */
    val fanout: Int? = null,
    /** `LINK_UP`／`STAT`：連線 RSSI，取得到才有。 */
    val rssi: Int? = null,
    /** 當下 app 的 `PowerManager.PowerMode`（不受系統省電模式影響，見 [sysSaver]）。 */
    val mode: String? = null,
    /** 當下的直連數。 */
    val nLinks: Int? = null,
    /** `STAT`：電量（%）。 */
    val batt: Int? = null,
    /** `STAT`：電池溫度（°C）。 */
    val temp: Double? = null,
    /** Android 系統省電模式是否開著，輸出為 `1`／`0`。 */
    val sysSaver: Boolean? = null
) {
    enum class Kind { TX, RX, DUP, RELAY, QFULL, LINK_UP, LINK_DOWN, STAT }

    fun toCsvRow(): String = listOf(
        tMs,
        ev.name,
        type?.let { "0x%02x".format(Locale.ROOT, it) },
        src,
        pts,
        ttl,
        len,
        peer,
        fanout,
        rssi,
        mode,
        nLinks,
        batt,
        temp?.let { "%.1f".format(Locale.ROOT, it) },
        sysSaver?.let { if (it) 1 else 0 }
    ).joinToString(",") { it?.toString() ?: "" }

    companion object {
        const val CSV_HEADER = "t_ms,ev,type,src,pts,ttl,len,peer,fanout,rssi,mode,n_links,batt,temp,sys_saver"

        /** peerID、senderID 只留前 8 碼（`docs/device-transport-test-matrix.md` 的隱私規範）。 */
        fun id8(id: String): String = id.take(8)
    }
}
