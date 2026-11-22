# Health Report 採分層揭露

> **後端的分級見 [ADR-0005](0005-detail-tier-for-all-sensitive-tier-for-helping-verified-rescuers.md)**：Firestore 上的 Detail Tier（姓名、居住區域、傷勢細項、精確座標）對所有登入帳號公開，電話、血型、病史與緊急聯絡人另外列為 Sensitive Tier。**位置見 [ADR-0008](0008-broadcast-tier-carries-precise-location.md)**：Broadcast Tier 與 Detail Tier 共用同一份精確座標。

原本的做法是把姓名、手機、血型、狀態、補充說明與精確經緯度包成單一明文結構，廣播給藍牙範圍內的所有裝置。我們把它拆成兩層：

- **Broadcast Tier**：隨機的 Reporter Handle、Status enum、精確座標，約 20 bytes。
- **Detail Tier**：真實姓名、電話、血型、自由文字。只在特定救援者提出請求時，透過既有的 Noise session 釋出。

Broadcast Tier 先做（A1）；Detail Tier 為條件性項目（A2），進度落後時第一個砍。

Broadcast Tier 的位置原本降為 geohash 精度 5，後來提高為 6，現在改為精確座標（ADR-0008）。分層要擋的是姓名與聯絡方式，不是位置。

## Considered Options

- **僅做最小化**（移除姓名與電話，但不做 Detail Tier）：成本最低，但救援者永遠無法取得聯絡方式。
- **整份加密給救援者公鑰**：需要事先佈建救援單位的金鑰，而真實災害中臨時投入的救援者，恰恰沒有這套基礎設施。
- **Broadcast Tier 只放降精度的位置**（本 ADR 原本的做法，geohash-5，後為 6）：不足以定位到本人，斷網時 Rescuer 也就找不到人。已由 ADR-0008 推翻。

## Consequences

- **這不是 R4 的成本，而是 R4 的一個變因。** 封包大小是壅塞的主導項。~150 bytes 對 ~18 bytes 是實驗 5 的自變數，隱私修正與效能結果是同一個改動。改成精確座標後 Broadcast Tier 約 21 bytes，不影響這個對比。
- **Broadcast Tier 不含姓名與聯絡方式，但精確座標足以走到 Reporter 面前。** 範圍內任何人都知道「某人重傷，就在這裡」，取捨見 ADR-0008。
- 救援者失去一跳內直接取得聯絡資訊的能力。A2 未完成時，App 只能顯示「某人重傷，就在此處」，卻無從聯繫，這是刻意接受的取捨。
- 線路格式改變，而且 Firestore 的 `status` 查詢鍵與 Status enum 的對應會散落兩處，必須由 R6 的測試向量鎖住。
- Health Report payload 原本**沒有版本位元組**（標頭的 version 是封包層級的），舊版裝置解新格式時會誤讀，而不是拒收。這次改動須一併補上 payload 版本欄位。
