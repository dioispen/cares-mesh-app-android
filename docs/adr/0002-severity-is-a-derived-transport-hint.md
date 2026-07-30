# Severity 是衍生的傳輸提示，不是傷勢狀態

封包標頭 `BitchatPacket.severity`（`UByte?`）與 payload 內的 `HealthReportPayload.status`（安全／輕傷／重傷）是兩個不同的東西，先前都被稱為「嚴重度」。我們確立：**Status 是領域事實，由 Reporter 自行宣告；Severity 是傳輸提示，由發送端裝置從 Status 推導而得**。Relay 端只讀到一個數字，`protocol/` 與 relay 程式碼永遠不知道那代表什麼傷勢。

## Consequences

- **標頭未加密。** 讓中繼者能不解密就做繞送決策，本質上就要求該欄位對不受信任的中間節點可讀，因此即使 payload 加密，範圍內的裝置仍能讀到粗略的緊急程度（三個值，約 1.5 bits）。這是繞送提示無法迴避的最小洩漏，須在報告中列為已知限制，而非佯稱不存在。
- **Severity 完全由發送者自我宣告**，`health_screen.dart` 讓使用者自己點選 Status，系統無從驗證。與其視為漏洞，我們把 Severity Inflation 納為明確的實驗軸（實驗 6），量測機制隨造假比例上升的退化曲線。「大家都標重傷怎麼辦」因此是一張已備好的圖，而不是一個答不出的問題。
- Status↔Severity 的對應必須是單一份程式碼，並納入 R6 的一致性測試向量；Firestore 以中文字串 `'輕傷'`／`'重傷'` 當查詢鍵，是最容易無聲失效的一環。
