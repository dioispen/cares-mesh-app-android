# Health Report 採分層揭露

現況是把姓名、手機、血型、狀態、補充說明與精確經緯度包成單一明文結構，廣播給藍牙範圍內的所有裝置。我們將其拆為 **Broadcast Tier**（不具識別性的 reporter handle、Status enum、降精度 geohash，約 18 bytes）與 **Detail Tier**（真實姓名、電話、血型、精確座標、自由文字；僅在特定救援者提出請求時，透過既有的 Noise session 釋出）。Broadcast Tier 先做（A1），Detail Tier 為條件性項目（A2），進度落後時第一個砍。

## Considered Options

- **僅做最小化**（移除姓名電話、降低座標精度，但不做 Detail Tier）：完整堵住隱私漏洞且成本最低，但救援者永遠無法取得聯絡方式。
- **整份加密給救援者公鑰**：需要事先佈建的救援單位金鑰，而真實災害中臨時投入的救援者恰恰沒有這套基礎設施。

## Consequences

- **這不是 R4 的成本，而是 R4 的一個變因。** 封包大小是壅塞的主導項；~150 bytes 對 ~18 bytes 是實驗 5 的自變數，隱私修正與效能結果是同一個改動。
- 救援者失去一跳內直接取得聯絡資訊的能力。A2 未完成時，App 只能顯示「某人重傷，位置約在此」而無從聯繫，這是刻意接受的取捨。
- 改變線路格式，且 Firestore 的 `status` 查詢鍵與 Status enum 的對應會散落兩處，必須由 R6 的測試向量鎖住。
- Health Report payload 目前**沒有版本位元組**（標頭的 version 是封包層級的），舊版裝置解新格式會誤讀而非拒收；本次改動須一併補上 payload 版本欄位。
