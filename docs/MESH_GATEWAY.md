# Mesh Gateway 規格

> 狀態：草案，尚未實作。
> 決策紀錄：[ADR-0008](adr/0008-broadcast-tier-geohash-precision-6.md)（geohash 精度 6）、[ADR-0009](adr/0009-gateway-uploads-broadcast-tier-from-kotlin.md)（Gateway 只代傳 Broadcast Tier、由 Kotlin 寫 Firestore）。
> 前提：ADR-0003（分層揭露）、ADR-0004（SOS 是 Health Report 上的標記，實作見 #105，須先合併）、ADR-0005（Detail／Sensitive Tier）、ADR-0006（驗簽 key 快取）。
> 領域語彙見 [CONTEXT.md](../CONTEXT.md)；本文新增 **Gateway** 與 **Administrator**。

## 1. 目標與範圍

**目標**：整段期間都沒有網路的 Reporter，其 Health Report 經 mesh 到達任何一支已登入、有網路的手機後，被寫進 Firestore，讓管理後台能以**村里、收容避難所的層級**統計各區有多少人需要協助。

**消費端**：另一組開發的 Flutter Web 管理後台，以 Administrator 帳號讀 Firestore。介面契約見[第 8 節](#8-給管理後台的介面契約)。

**不在範圍內**：

- 代傳 Detail Tier 或 Sensitive Tier、任何加密（ADR-0009）。
- 伺服器端驗簽、Cloud Functions（不開 Blaze 方案）。
- 自動刪除 `mesh_reports`。
- App 內顯示 gateway 上傳的資料；互助任務維持原樣。
- 改動 Relay Decision、TTL 或 gossip sync。
- 管理後台本身的畫面與統計邏輯（另一組負責）。

## 2. 資料流

```
Reporter A（無網路）
  │  HEALTH_REPORT（簽章明文，Broadcast Tier，geohash-6）
  ▼
mesh：flood（TTL 3）或 gossip sync 補送（TTL 0，2 小時內）
  │
  ▼
Gateway G（已登入、gateway 開啟）
  MessageHandler.handleHealthReport ── 驗證通過、可解碼、非實驗 Handle
  │
  ├─ 有網路 ──► set mesh_reports/{reporterHandle}
  └─ 沒網路 ──► 記憶體暫存（每個 Handle 最新一份，≤ 2 小時）── 網路恢復 ──► set

Reporter（曾經有網路、已登入）
  └─ App 啟動 ──► set reporter_handles/{uid}/installations/{reporterHandle}

管理後台（Administrator）
  └─ 讀 mesh_reports、reporter_handles、health_reports，統計與去重
```

## 3. 線路格式變更（ADR-0008）

| 項目 | 現在 | 改後 |
|---|---|---|
| Kotlin `DisasterReportPacket.GEOHASH_PRECISION` | 5 | 6 |
| Dart `HealthReportPayload.geohashPrecision`（`ble_packet_decoder.dart`） | 5 | 6 |
| 解碼端接受的 `geohashLen` | 0 或 5 | **0 或 6** |
| `MAX_ENCODED_SIZE` | 19 | 20 |
| payload 版本 | 不變 | 不變 |

- 兩端的權威向量（`DisasterReportTest`、`health_report_payload_test.dart`）同步更新。
- 舊版裝置與新版互相拒收；所有裝置一起更新，實機實驗期間不混用。
- `DisasterReportPacket.kt` 中「geohash-5 ≈ 數公里見方」的說明改寫。

## 4. 名詞

- **Gateway**：已登入、有網路且開啟代傳的裝置，把經 mesh 收到的別人的 Health Report（Broadcast Tier）寫進 Firestore。與 Relay 不同：Relay 把封包送往 mesh，Gateway 把它送往後端。
- **Administrator**：`admins/{uid}` 文件存在的帳號，只能由 Firebase console 或 Admin SDK 授予。讀得到 `mesh_reports` 與 `reporter_handles`。與 Verified Rescuer 是兩個獨立的角色。

## 5. Firestore 資料模型

### 5.1 `admins/{uid}`

文件存在即為 Administrator，內容不限。比照 `rescuers/{uid}`：本人可讀自己那份，客戶端一律不可寫。

### 5.2 `mesh_reports/{reporterHandle}`

每個 Reporter Handle 一份文件，只保留 `reportTime` 最新的回報。文件 ID 是小寫的 12 個十六進位字元。

| 欄位 | 型別 | 說明 |
|---|---|---|
| `schemaVersion` | int | 固定為 `1` |
| `reporterHandle` | string | 與文件 ID 相同 |
| `status` | string | `安全`／`輕傷`／`重傷`／`未宣告`，與 `health_reports.status` 同一組值 |
| `sos` | bool | Reporter 正舉著 SOS |
| `geohash` | string 或 null | 6 碼；Reporter 沒有位置時為 null |
| `reportTime` | timestamp | payload 的回報時間（Reporter 手機的時鐘，精度到秒） |
| `uploadedAt` | timestamp | 伺服器時間（寫入時的 `request.time`） |
| `gatewayUid` | string | 寫入者的 uid |
| `senderPeerId` | string | 封包標頭的 `senderID`（16 個十六進位字元） |
| `rawPacket` | bytes | 收到的 HEALTH_REPORT 封包原樣編碼，含 content tag 與簽章 |
| `announcement` | bytes 或 null | 發送者經過驗證的已簽章 ANNOUNCE；取不到時為 null |

- `rawPacket` 與 `announcement` 是日後驗簽的材料（ADR-0009），現在沒有人驗。`rawPacket` 必須是**收到時的編碼**，而不是 `MessageHandler` 剝掉 content tag 之後的版本。重新編碼時要保留收到時的壓縮狀態（見 `BinaryProtocol` 對 preimage 的說明）。
- `announcement` 取自 `HealthReportSigningKeyCache.announcementFor`：每份通過驗證的 ANNOUNCE 都會記進這份快取，保留 2 小時（ADR-0006），與 gateway 的暫存期限相同。
- 一份文件約 500 bytes 以內。

### 5.3 `reporter_handles/{uid}/installations/{reporterHandle}`

Reporter 本人登記「這次安裝的 Handle 屬於我」。一個帳號可以有多支手機（多份文件）；一支手機先後登入不同帳號時，同一個 Handle 會出現在多個 uid 底下。

| 欄位 | 型別 | 說明 |
|---|---|---|
| `reporterHandle` | string | 與文件 ID 相同 |
| `signingPublicKey` | bytes | 本機 Ed25519 簽章公鑰（32 bytes，即 ANNOUNCE 中那一把） |
| `registeredAt` | timestamp | 伺服器時間 |

登出時不刪除。

## 6. Firestore 規則

以下是規則要達成的條件，實作時寫進 `firestore.rules`，並在 `firestore-tests/rules.test.mjs` 補上對應測試。

```
function isAdmin() {
  return request.auth != null
      && exists(/databases/$(database)/documents/admins/$(request.auth.uid));
}

match /admins/{uid} {
  allow read: if request.auth != null && request.auth.uid == uid;
  allow write: if false;
}

match /mesh_reports/{handle} {
  allow read, delete: if isAdmin();
  allow create: if validMeshReport(handle);
  allow update: if validMeshReport(handle)
                && request.resource.data.reportTime > resource.data.reportTime;
}

match /reporter_handles/{uid}/installations/{handle} {
  allow read: if isAdmin() || isOwner(uid);
  allow create, update: if isOwner(uid) && validInstallation(handle);
  allow delete: if isAdmin() || isOwner(uid);
}
```

`validMeshReport(handle)` 必須全部成立：

- `request.auth != null`，且 `gatewayUid == request.auth.uid`。
- 鍵只能是 5.2 列出的那些，型別正確，`schemaVersion == 1`。
- `handle` 符合 `^[0-9a-f]{12}$`，且等於 `reporterHandle`。
- `status` 屬於四個值之一；合法組合依 ADR-0004：`安全` 不可帶 SOS，`未宣告` 必須帶 SOS。
- `geohash` 為 null 或長度 6。
- `uploadedAt == request.time`。
- `reportTime <= request.time + 10 分鐘`（容忍時鐘誤差，並防止用未來時間鎖住文件）。
- `reportTime >= request.time - 2 小時 10 分鐘`（不接受超過保留期限的舊回報）。
- `rawPacket` 不超過 1 KB；`announcement` 為 null 或不超過 1 KB。

`validInstallation(handle)`：鍵只能是 5.3 列出的那些；`handle` 符合 `^[0-9a-f]{12}$` 且等於 `reporterHandle`；`signingPublicKey` 為 32 bytes；`registeredAt == request.time`。

注意：`mesh_reports` 的 update 要求 `reportTime` **嚴格遞增**。同一秒內送出的第二份回報會被拒；這種情況極少見，接受。

## 7. Gateway 行為

### 7.1 程式位置與生命週期

- 新的 Kotlin 元件（暫名 `MeshGateway`，放在 `service/` 或新的 `gateway/` 套件）由 `MeshForegroundService` 建立與停止，生命週期與 mesh 相同。
- Firebase 程式碼不進 `mesh/`：`MessageHandler` 透過一個類似 `InboundPacketBridge` 的 hook 把回報交出去，`mesh/` 不依賴 Firebase。
- `app/build.gradle.kts` 新增 `firebase-firestore`、`firebase-auth`（版本由現有 BoM 決定）。
- CLAUDE.md 架構限制第 5 條同步改寫（ADR-0009）。

### 7.2 掛載點

在 `MessageHandler.handleHealthReport` 中，**通過**未驗證 peer 檢查、`HealthReportPayload.decode` 成功、**不是** `ExperimentHandles` 的 Handle 之後，把以下三樣交給 hook：

- 收到時的**原始封包**（含 content tag；`handleTaggedBroadcast` 剝 tag 之前的那一份，需要一路傳下來）
- 解碼後的 `HealthReportPayload`
- 發送者 peerID

即時 flood 與 gossip sync 補送的回報都經過這條路徑，不需區分。自己的封包在 `handleMessage` 開頭就被濾掉，不會進來。

### 7.3 上傳條件

全部成立才上傳：

1. 使用者沒有關閉 gateway（[7.6](#76-設定與同意)）。
2. `FirebaseAuth.getInstance().currentUser != null`。
3. `now - reportTime <= HEALTH_REPORT_RETENTION_MS`（2 小時）。
4. `reportTime` 比本機記錄的「這個 Handle 已上傳過的最新 `reportTime`」更新。

條件 1、2 不成立時直接丟棄，不暫存。條件 3、4 不成立時丟棄。

### 7.4 有網路／沒網路

- 「有網路」的定義：`ConnectivityManager` 的預設網路具備 `NET_CAPABILITY_INTERNET` 與 `NET_CAPABILITY_VALIDATED`。以 `registerDefaultNetworkCallback` 監聽。
- **有網路**：立即寫入。
- **沒網路**：放進記憶體暫存。每個 Handle 只留 `reportTime` 最新的一份；超過 2 小時的在補傳前剔除；上限比照 `HealthReportSigningKeyCache` 的 1000 筆，滿了剔除最舊的。**不寫磁碟**。
- **網路恢復、或使用者登入、或重新開啟 gateway 時**：依 7.3 的條件重新檢查暫存，逐筆寫入。
- 暫存的語意與 `GossipSyncManager` 保留的 Health Report 相同（每個發送者最新一份、2 小時）。但暫存由 gateway 自己持有、只收經過 7.2 掛載點的回報，以確保補傳的都通過驗證與實驗 Handle 過濾，也不讓 Firebase 程式碼耦合到 `sync/`。

### 7.5 寫入與去重

- 用 `set`（整份覆寫，不 merge）寫 `mesh_reports/{reporterHandle}`，`uploadedAt` 用 `FieldValue.serverTimestamp()`。
- **成功**：記下該 Handle 的 `reportTime`，從暫存移除。
- **`PERMISSION_DENIED`**：最可能是其他 gateway 已寫入同一份或更新的回報（規則要求嚴格遞增），**視同成功**處理：記下 `reportTime`、從暫存移除。同時記一筆 log，方便排查是否為欄位或規則錯誤。
- **`UNAVAILABLE` 等暫時性錯誤**：留在暫存，等下一次網路事件再試。
- 不先讀再寫，以節省 Spark 方案每天 50,000 次讀取的額度。寫入額度為每天 20,000 次；Health Report 只在使用者送出時發送、不會定期重送，加上本機去重，量級在額度之內。
- 「已上傳過的最新 `reportTime`」只放記憶體；service 重啟後重傳一次會被規則拒絕並視同成功，不影響正確性。
- 寫到一半斷線的那一筆可能留在 Firestore SDK 的磁碟佇列裡（ADR-0009 已接受）。

### 7.6 設定與同意

- 新設定「代傳附近的求救與回報」，**預設開啟**。
- 值存在 Kotlin 端的 SharedPreferences，讓 service 在 Flutter 不存在時也讀得到；透過 `SettingsBridge`（`settings_` 前綴）讓 Flutter 設定畫面讀寫。
- 設定畫面的說明要寫明：開啟時，你的帳號會被記錄為代傳者，管理員因此能推得你當時大致在哪一區。
- `PRIVACY_POLICY.md` 新增 gateway 一節：上傳了什麼（他人的 Broadcast Tier、原始封包、代傳者 uid）、誰讀得到（只有 Administrator）、如何關閉。
- 未登入的手機不是 gateway，也不提示。

### 7.7 `reporter_handles` 登記（Flutter）

- 時機：App 啟動時與登入成功後，只要已登入就 `set` 一次（idempotent）。不等到送出回報，因為最需要這份對應的，正是登記之後就再也沒有網路的人。離線時交給 Firestore 的離線佇列（這是本人的資料，與 Flutter 端其他寫入一致）。
- Handle：`loadOrCreateReporterHandle`（`own_report_cache.dart`）。
- 簽章公鑰：新增一個 bridge 方法，從 Kotlin `EncryptionService.getSigningPublicKey()` 取得。
- 失敗不提示使用者，下次啟動再試。

## 8. 給管理後台的介面契約

這一節給負責管理後台的組別，可以單獨閱讀。

**登入**：使用 Administrator 帳號。由專案管理者在 Firebase console 建立 `admins/{你的 uid}` 文件（內容不限）。一般帳號、Verified Rescuer 都讀不到以下資料。

**`mesh_reports`**：經由 mesh 代傳上來的回報，每個 Reporter Handle 一份，欄位見 [5.2](#52-mesh_reportsreporterhandle)。

- 這些 Reporter **在上傳當時沒有自己連上網路**，所以沒有姓名、電話、精確座標。
- `geohash` 是 6 碼，一格約 0.6 × 1.1 km。用任何 geohash 函式庫解出格子的邊界或中心點。null 代表 Reporter 沒有提供位置。
- 「需要協助」的判斷與 App 的互助任務一致：`sos == true`，或 `status` 為 `輕傷`、`重傷`。`sos == true` 的優先。
- `reportTime` 來自 Reporter 手機的時鐘，可能不準；`uploadedAt` 是伺服器時間。判斷「回報還有效」的時間窗由後台決定，建議同時參考兩者。
- 同一份文件被更新時，代表同一個 Reporter 發了新回報。SOS 撤回或改報「安全」也是一次更新（`sos` 變 false）。
- `gatewayUid`、`senderPeerId`、`rawPacket`、`announcement` 是稽核與日後驗簽用的，統計時可以忽略。

**與 `health_reports` 去重**：同一個人可能同時在 `health_reports/{uid}`（本人上傳，Detail Tier）與 `mesh_reports/{handle}`（他人代傳）出現。

1. 以 collection group 查詢 `installations` 中 `reporterHandle == handle` 的文件，路徑上層就是 uid。這需要在 console 為 `installations.reporterHandle` 建立 collection group 範圍的單一欄位索引。
2. 若有多個 uid 宣稱同一個 Handle，以 `registeredAt` 最新的為準；若其中一份的 `signingPublicKey` 與 `mesh_reports` 原始封包的簽章 key 不符，那一份是冒領（見第 9 節）。
3. 找到 uid 後，兩份回報取時間較新的那一份。`health_reports.reportTime` 是 ISO-8601 字串，`mesh_reports.reportTime` 是 timestamp，比較前先轉換。
4. 找不到 uid 的 Handle，代表 Reporter 從未在有網路時登入過，只能當作一個匿名的人計算。

**信任程度**：這些資料**沒有經過伺服器驗證**。任何登入帳號都能直接寫 `mesh_reports`，包括偽造 SOS，或用真實 Handle 寫一份「安全」蓋掉真的 SOS。異常時可以用 `gatewayUid` 追查寫入者。

**刪除**：App 不會刪除任何 `mesh_reports`。災害結束後由 Administrator 清空，規則只允許 Administrator 刪除。

**計數的限制**：一個 Handle 代表一次 App 安裝，不是一個人。共用手機的人會算成一人，沒有手機的人不會出現，重裝 App 的人會算成兩人。格子邊界也不對應行政區，跨村里的格子只能依中心點歸屬。

## 9. 已知限制

| 限制 | 影響 | 日後處理方式 |
|---|---|---|
| 伺服器端不驗簽 | 偽造回報、用「安全」蓋掉真的 SOS | 用 `rawPacket`、`announcement` 在後台或 Functions 驗簽 |
| Handle 冒領 | 攻擊者把聽到的 Handle 登記在自己 uid 底下 | 比對 `signingPublicKey`；長期改用自我認證的 Reporter Handle（ADR-0006） |
| 管理員可推得 gateway 的大略位置 | 即時 flood 收到的回報，`gatewayUid` 代表該帳號當時在附近 | 預設開啟、可關閉、隱私政策揭露 |
| 寫到一半斷線的那一筆會落在磁碟佇列 | 短暫違反「只放記憶體」 | 若不可接受，改用 REST 寫入（ADR-0009 Considered Options） |
| `gatewayUid` 只記錄第一個成功寫入的 gateway | 看不出有幾支 gateway 收到同一份 | 改為每支 gateway 各寫一筆子文件，寫入量會乘上 gateway 數 |
| 同一秒內的兩份回報，後者會被拒 | 極少見 | — |
| 只有已登入的手機能當 gateway | 覆蓋率取決於有多少人登入 | — |

## 10. 測試與驗收

**Kotlin 單元測試**

- 精度 6 的編解碼向量；長度 5 的 geohash 被拒收。
- 掛載點：交給 hook 的是含 content tag 的原始封包；未驗證 peer、解碼失敗、實驗 Handle 都不會交出。
- `MeshGateway`（以假的上傳介面測試）：
  - 7.3 的每一個條件各自擋得住。
  - 離線暫存：每個 Handle 只留最新一份、超過 2 小時剔除、上限剔除最舊的。
  - 網路恢復時補傳。
  - 成功與 `PERMISSION_DENIED` 都會記下 `reportTime` 並移出暫存；暫時性錯誤保留在暫存。
  - 關閉設定或登出時不上傳、不暫存。

**Dart 測試**

- `ble_packet_decoder` 的精度 6 向量。
- `reporter_handles` 登記：只在已登入時寫入，欄位正確。

**規則測試**（`firestore-tests/rules.test.mjs`）

- `admins`：本人可讀自己，客戶端不可寫。
- `mesh_reports`：
  - 只有 Administrator 能讀、能刪。
  - 登入者可建立格式正確的文件；`gatewayUid` 不是自己時被擋。
  - 多餘欄位、`status` 非法、`安全` 帶 SOS、`未宣告` 不帶 SOS、geohash 長度不是 6、`reportTime` 太新或太舊，都被擋。
  - update 時 `reportTime` 沒有嚴格遞增被擋。
- `reporter_handles`：只有本人能寫自己 uid 底下的文件；Administrator 與本人可讀，其他人不可讀；`signingPublicKey` 長度不對被擋。

**實機驗收**（三支手機：A 無網路的 Reporter、B 無網路的 relay、C 有網路的 gateway）

1. A 舉起 SOS → 一分鐘內出現 `mesh_reports/{A 的 Handle}`，`sos == true`，`gatewayUid` 是 C。
2. A 撤回 SOS → 同一份文件更新為 `sos == false`。
3. C 開飛航模式時收到 A 的回報 → C 關閉飛航模式後補傳。
4. C 關閉 gateway 設定 → 不再上傳。
5. C 滑掉 App 畫面（service 仍在）→ 仍會上傳。
6. 用非 Administrator 帳號讀 `mesh_reports` → 被拒。
7. A 曾在有網路時登入 → `reporter_handles/{A 的 uid}/installations/{A 的 Handle}` 存在。

## 11. 實作順序

建議拆成四個 PR，依序合併：

1. **geohash 精度 6**（ADR-0008）：Kotlin、Dart、權威向量。這個 PR 本身就讓所有裝置必須一起更新。
2. **Firestore 規則**：`admins`、`mesh_reports`、`reporter_handles`，以及規則測試。
3. **`reporter_handles` 登記**：Flutter 端與取得簽章公鑰的 bridge 方法。
4. **Kotlin gateway**：`MeshGateway`、掛載點、設定開關、Firebase 依賴、`PRIVACY_POLICY.md`、CLAUDE.md 第 5 條。

PR 2 合併後，就可以通知管理後台那組依第 8 節開工。
