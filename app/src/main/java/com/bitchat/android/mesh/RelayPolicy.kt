package com.bitchat.android.mesh

/**
 * Relay Decision 的政策參數，經 [PacketRelayManager] 的建構子注入。
 *
 * 預設值等於現行行為：production 接線（[PacketProcessor]）不傳，實機行為不變。policy-level 模擬器
 * （#1、ADR-0001）會經同一個建構子換掉它。欄位都是純量，模擬結果檔可以原樣記錄。
 */
data class RelayPolicy(
    /**
     * 遞減後 TTL ≥ 此值的封包一律轉發，跳過依網路規模的轉發機率（#1 R13）。
     *
     * 預設 4：以 `AppConstants.MESSAGE_TTL_HOPS`（7）送出的封包，前 3 代轉發一律送出。要讓每一跳都走
     * 機率路徑，調成 `UByte.MAX_VALUE`：遞減後的 TTL 最大只有 254。Health Report 的 TTL 刻意與這個
     * 門檻搭配，見 `AppConstants.HEALTH_REPORT_TTL_HOPS`。
     */
    val unconditionalRelayTtl: UByte = 4u
)
