# SOS 是 Health Report 上的標記，不是獨立的廣播內容

SOS 原本是另一條路徑：只寫入 Firestore 的 `sos_requests`，斷網時送不出去，App 內也沒有任何畫面讀取。我們把 SOS 改定為 **Health Report 上的標記**：與 Health Report 共用 `HEALTH_REPORT` 封包與 `HealthReportPayload`，在 payload 加一個 SOS 欄位並把 `VERSION` 升為 2；Firestore 端同樣改為 `health_reports` 文件上的欄位。理由是 SOS 要廣播的內容（reporter handle、geohash、時間）與 Broadcast Tier 完全相同，兩者只差「是否請求救援」——這是同一份回報的屬性，不是另一種結構的內容。

## Considered Options

- **使用 `BinaryProtocol.kt` 預留的 `BroadcastContentTag.SOS(0x02)`**：payload 大小不變，但 content tag 用來區分不同結構的內容（例如未來的 `SUPPLY_REQUEST`）；tag 在 `MessageHandler.handleTaggedBroadcast()` 就被剝除，到不了 Flutter；舊版裝置雖然會拒收，但原因是把 tag `0x02` 誤讀成 payload 版本 2，屬於巧合。
- **把 SOS 做成 Status 的一個值**：SOS 不是身體狀況，會失去「SOS＋重傷」這種組合。
- **維持獨立的 `sos_requests` collection**：兩者的讀取規則會各自演變，#64 就是這樣產生的。

## Consequences

- **Payload 版本 1 → 2，舊版裝置會拒收所有新版 Health Report，不只 SOS。** 原型階段所有裝置一起更新，可以接受；但實機實驗期間不能混用版本，因此實作排在實驗之後。Broadcast Tier 上界由 18 增為 19 bytes，不影響 F3（~150 B 對 ~18 B）的結論。
- **SOS 由發送端持有**：Reporter 舉起 SOS 後，之後的每一份 Health Report 都帶著標記，直到撤回或回報「安全」為止；接收端對同一 reporter handle 以 `reportTime` 最新的一份為準。因此撤回 SOS 不需要另外的封包。
- **Status 多一個值「未宣告」**：舉起 SOS 時沿用最近一次的輕傷／重傷；從未回報過、或最近一次是「安全」時，Status 為「未宣告」。所以「安全」與 SOS 不會同時成立，帶 SOS 的回報其 Status 必定是輕傷、重傷或未宣告。Kotlin `HealthStatus`、Dart `statusByWire` 與 Firestore 的 `status` 查詢鍵都要涵蓋這個新值。
- **與 ADR-0002 的關係**：`BitchatPacket.severity` 目前沒有任何程式設定或讀取。ADR-0002 規定 Severity 由 Status 推導；SOS 是否納入推導，留到 R5（severity-aware relay）實作時決定。在那之前，SOS 不影響 Relay Decision。
