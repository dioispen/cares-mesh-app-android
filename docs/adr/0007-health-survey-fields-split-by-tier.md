# 健康回報的狀況調查依 ADR-0005 的分級拆進兩份文件

健康回報從「選一個 Status」改為完整的狀況調查表，用來和 SOS 做出區別：SOS 是有立即危險時長按送出的求救；健康回報是情況沒那麼緊急的 Reporter，填寫較完整的狀況，讓管理中心安排物資與關懷、讓附近的人知道怎麼幫。

調查表除了 Status 與傷勢，新增七題。依 ADR-0005 的分級，這些欄位分別放進兩份文件：

- **Detail Tier**（`health_reports/{uid}.survey`，任何登入帳號可讀）：行動能力、所在地點類型、同住或同行人數、住家狀況、最需要的協助。附近想幫忙的人在接任務**之前**就需要知道要帶什麼（水、藥）、要不要協助移動、要容納幾個人——放進 Sensitive Tier 的話，只有已經接了任務的 Verified Rescuer 看得到，失去了互助的意義。
- **Sensitive Tier**（`health_report_sensitive/{uid}.surveySensitive`）：身邊需要特別照顧的人（長者、幼童、孕婦、身心障礙者、慢性病患、寵物）、Reporter 本人需要特別照顧的情況（長者、孕婦、身心障礙者、慢性病患，`selfVulnerable`），以及自由文字的補充說明。前兩者會透露本人或家人的身心障礙、慢性病或懷孕，屬於病史同一類；後者是自由文字，無法保證使用者不寫進病史或聯絡方式。

傷勢不另開欄位，沿用 Detail Tier 的 `description`（多個以「、」連接），互助任務看到的傷勢細項維持原意。

## Considered Options

- **整份調查放在 Detail Tier**：最簡單，但「家中有身心障礙者」等於公開病史，違反 ADR-0005 對病史的分級。
- **整份調查放在 Sensitive Tier**：最保守，但一般使用者接任務前看不到對方缺什麼，互助任務退化成只看傷勢與座標。
- **依題目敏感度拆開**（採用）：公開「怎麼幫」需要的資訊，保護「誰有什麼病」。

## Consequences

- **規則鎖住巢狀 map 的鍵**：最外層的 `keys().hasOnly()` 擋不到 `survey` 裡的內容，所以 `firestore.rules` 另以 `mapFieldHasOnly()` 限制 `survey` 只能有 `detailSurveyKeys()`、`surveySensitive` 只能有 `sensitiveSurveyKeys()`。日後要新增題目，必須先決定它屬於哪一層，再同時改模型（`HealthSurvey.toDetailMap`／`toSensitiveMap`）與規則。
- **兩份文件的調查欄位刻意不同名**（`survey`／`surveySensitive`），維持「兩份文件除了 `reporterId` 不共用任何欄位」的不變式（`health_report_test`）。
- **只改調查、不改 Status 與傷勢時不重置互助任務**：`taskStatus`／`helperId` 的重置條件仍是 Status 或傷勢改變（`contentChanged`），更新「需要的協助」不會讓已經在路上的 Helper 丟掉任務。
- **調查內容不進 BLE 廣播**：Broadcast Tier 仍只有 handle、Status、geohash 與時間（ADR-0003）。
- 隱私政策第 2 節同步列出新增的項目與其所屬的層級。
