# 管理端公告 v1（ADMIN_NOTICE）

> 狀態：草案，尚未實作。管理後台的發送頁面與 Dart 加解密是否由另一組實作，確認中；若不接，改由本專案以 `tools/admin-notice/` 的 Python 工具發送。
> 決策紀錄：[ADR-0011](adr/0011-admin-notice-trusts-admin-signature-only.md)（只信任管理端簽章、新封包類型 0x31）。
> 前提：ADR-0006（驗簽 key 快取只用於 Health Report）、ADR-0009（Administrator、Kotlin 端的 Firestore）、[MESH_GATEWAY.md](MESH_GATEWAY.md)（Gateway 送出 mesh 的方向、`reporter_handles`）。
> 領域語彙見 [CONTEXT.md](../CONTEXT.md)；本文新增 **Admin Notice**（下稱公告），並用到雙向的 **Gateway**。

Administrator 從管理端（管理後台，Flutter Web）發公告給用戶端：廣播給所有人，或指定帳號、Reporter Handle 單播、組播。有網路的用戶端從 Firestore 收到後注入 BLE mesh，再由 mesh 洪泛與 gossip sync 送到離線的人手上。信任只來自管理端簽章，理由見 ADR-0011。

## 範圍

v1 包含：

- 廣播、單播、組播（每則最多 5 個收件裝置，超過由管理端拆成多則）
- 管理端 Ed25519 簽章，所有節點端到端驗證
- 單播與組播的內容加密給收件者
- 撤回與取代
- 納入 gossip sync，補送到到期為止
- 單播與組播的送達、已讀回條

v1 不做：

- FCM 推播（App 被殺掉時喚醒）。需要 Blaze 方案，留到第二階段。
- 固定群組與群組金鑰
- 依公告等級調整轉送優先順序（Severity-aware Relay 仍在 ADR-0001、ADR-0002 的研究範圍）
- 勿擾模式下響鈴、full-screen intent、語音播報
- 廣播的送達統計
- 與 iOS bitchat 互通

## 角色

| 角色 | 說明 |
|---|---|
| 管理端 | 另一組以 Flutter Web 開發的管理後台（[MESH_GATEWAY.md](MESH_GATEWAY.md) 第 1 節），由 Administrator（`admins/{uid}`，ADR-0009）登入操作。後台只是靜態網頁、直接連 Firestore，沒有伺服器可以保管私鑰，所以簽章與加密都在瀏覽器裡進行，私鑰由操作者每次載入（見「金鑰」） |
| Gateway | 見 [CONTEXT.md](../CONTEXT.md)：Gateway 是雙向的，送出 mesh 的方向見 [MESH_GATEWAY.md](MESH_GATEWAY.md)，本文只談注入 mesh 的方向。mesh 服務在跑、已登入、Firestore listener 連得上的裝置就是 Gateway，誰是 Gateway 隨網路狀況變動，不需要指定。「代傳附近的求救與回報」開關只管送出的方向，不影響注入：注入的封包是正規化的，不會記下是哪支手機注入的（ADR-0011） |
| 中繼 | mesh 裡任何轉送 0x31 的節點，包括看不懂 0x31 的舊版 App |
| 收件者 | 廣播是所有人；單播與組播是解得開內容的裝置。收件對象可以指定帳號（uid，涵蓋它登記過的每台裝置）或 Reporter Handle（一台裝置，例如在 `mesh_reports` 上看到的） |

## 流程

```text
管理端
  └─ 簽章（定向公告先加密）→ 寫入 admin_notices/{messageId}.wire
        └─ Gateway：MeshForegroundService 裡的 Firestore snapshot listener
              ├─ 驗簽 → 本機呈現；是收件者就寫回條（via=firestore）
              └─ 隨機等 0–15 秒；期間從 BLE 聽到同一則就不注入，否則注入 0x31
                    └─ mesh 洪泛（TTL 7）＋ gossip sync 補送到 expiresAt
                          └─ 每個節點：驗簽 → 去重 → 轉送；解得開的才呈現、寫回條（via=ble）
```

## 金鑰

### 管理端簽章金鑰

- Ed25519。所有操作者共用一把（keyId `0x01`）。私鑰是一個由操作者自己保管的檔案，每次發公告前在管理後台選檔載入，只放在該分頁的記憶體裡，關閉分頁就消失。後台**不得**把它寫進 localStorage、IndexedDB、Firestore 或任何雲端。
- 管理後台的加解密用純 Dart 實作（例如 `package:cryptography`），不依賴瀏覽器 WebCrypto 對 Ed25519、X25519 的支援程度。編碼 issuedAt 等 64 位元欄位時**不要用 `ByteData.setUint64`**：編譯成 JavaScript 時它會丟 `UnsupportedError`，要拆成兩個 32 位元寫入。
- App 內建 `keyId → 32 bytes 公鑰` 的對照表。`0x00` 保留不用。
- 換 key：先發一版同時內建新舊兩把的 App，多數使用者更新後管理端改用新 key，再發一版移除舊 key。
- 私鑰外洩：發一版移除該 key 的 App。使用者更新之前，偽造的公告仍會被接受（見已知限制）。
- 私鑰檔在操作者之間的分發與備份是手動作業，寫在管理端的操作手冊裡。

### 收件者加密金鑰

- 每次安裝的 App 在每次登入時產生一組 X25519 金鑰，綁定當時登入的 uid。私鑰存在 Kotlin 端的 EncryptedSharedPreferences，解密才能在背景進行。
- 公鑰登記在 `reporter_handles/{uid}/installations/{reporterHandle}` 的 `noticePublicKey`，與 Reporter Handle、簽章公鑰同一份文件，沿用 [MESH_GATEWAY.md](MESH_GATEWAY.md) 7.7 的登記：App 啟動時與登入成功後由 Flutter 整份 `set` 一次。公鑰經新增的 bridge 方法 `adminNotice_getPublicKey(uid)` 從 Kotlin 取得；傳入的 uid 與私鑰綁定的不同時，Kotlin 先刪除舊私鑰再產生新的。一個帳號登記過幾台裝置，就有幾把公鑰。
- 登出時 Flutter 呼叫 `adminNotice_clearKey`，要求 Kotlin 刪除私鑰。登記文件照 MESH_GATEWAY.md 5.3 不刪除：同一支手機改登入另一個帳號後，前一個帳號底下那份文件留著的是私鑰已刪除的公鑰，加密給它不會外洩內容，只會佔掉一個收件裝置的名額。
- **不得重用 Noise 靜態金鑰**，理由是金鑰分離，以及 Noise 靜態金鑰跨帳號不變：同一支手機換帳號登入後，仍解得開前一個帳號的定向公告。登記這把公鑰不會多出新的連結：Administrator 本來就能從 `reporter_handles` 與 `mesh_reports` 把 uid、Reporter Handle、peerID 串在一起（ADR-0009）。

## 線路格式

### 外層封包

Gateway 注入的封包是**正規化**的，不同 Gateway 注入同一則公告會得到同一個封包，`PacketIdUtil` 算出的封包 ID 相同（ADR-0011）：

| 欄位 | 值 |
|---|---|
| version | `1` |
| type | `0x31`（`MessageType.ADMIN_NOTICE`） |
| TTL | 注入時 `AppConstants.MESSAGE_TTL_HOPS`（7）；sync 回應照既有規則用 `SYNC_TTL_HOPS` |
| timestamp | 公告的 issuedAt |
| senderID | 公告的 messageId（8 bytes） |
| recipientID | 不帶（`HAS_RECIPIENT` 清除） |
| 裝置簽章 | 不帶（`HAS_SIGNATURE` 清除） |
| severity、route | 不帶 |
| payload | 公告 payload，即 Firestore 的 `wire`，原封不動 |

壓縮照 `BinaryProtocol` 既有規則處理。管理端簽章涵蓋的是解壓縮後的 payload，與傳輸層壓縮無關。

### Payload

多位元組整數一律 big-endian。

| offset | 長度 | 欄位 | 說明 |
|---|---|---|---|
| 0 | 1 | version | `0x01` |
| 1 | 1 | kind | `0x01` 廣播、`0x02` 定向（單播與組播） |
| 2 | 1 | keyId | 管理端簽章金鑰的 ID |
| 3 | 1 | level | `0x01` 資訊、`0x02` 重要、`0x03` 緊急 |
| 4 | 8 | messageId | 隨機值，不得全為 0 |
| 12 | 8 | issuedAt | Unix epoch 毫秒 |
| 20 | 8 | expiresAt | Unix epoch 毫秒 |
| 28 | 8 | replaces | 被取代的 messageId；全為 0 表示沒有 |
| 36 | 不定 | body | 依 kind 而定，見下 |
| 結尾 | 64 | signature | 管理端 Ed25519 簽章 |

前 36 bytes 稱為 header。body 是 header 之後、簽章之前的所有 bytes。

### 簽章

```text
signature = Ed25519.sign(adminKey, "CARES-ADMIN-NOTICE-v1" || payload[0 : len-64])
```

前綴是 21 bytes 的 ASCII 字串，沒有結尾的 0，用途是讓這把 key 簽出的東西不能被拿去冒充別的格式。

### 廣播 body

UTF-8 文字，0–300 bytes。只有 replaces 不為 0（純撤回）時才可以是空的。

### 定向 body

| 欄位 | 長度 |
|---|---|
| ephemeralPublicKey | 32 |
| recipientCount | 1（1–5） |
| 每個收件裝置：tag ‖ wrappedKey | 40 × recipientCount（8 + 32） |
| nonce | 12 |
| ciphertext ‖ GCM tag | 內容長度 + 16 |

管理端加密：

1. 產生一次性的 X25519 金鑰 `e`、32 bytes 隨機 `contentKey`、12 bytes 隨機 `nonce`。
2. 對每個收件裝置的 `noticePublicKey` `R`：
   ```text
   shared     = X25519(e.private, R)          # 全為 0 時中止
   okm        = HKDF-SHA256(ikm = shared,
                            salt = messageId,
                            info = "CARES-ADMIN-NOTICE-v1/recipient" || e.public || R,
                            length = 40)
   tag        = okm[0:8]
   wrappedKey = contentKey XOR okm[8:40]
   ```
3. `ciphertext ‖ GCM tag = AES-256-GCM(contentKey, nonce, plaintext = 內容 UTF-8, aad = header)`。內容 0–300 bytes。
4. 收件者條目以隨機順序排列。

收件者解密：用自己的私鑰與 `ephemeralPublicKey` 算出 `shared` 與 `okm`，以常數時間比對每個條目的 tag。比對到就還原 `contentKey` 解密；GCM 驗證失敗視為不是收件者。全部比對不到就不是收件者，不呈現，但照常轉送。

tag 由 ECDH 推出，每則公告都不同：只有收件者自己算得出來，旁人無法把兩則公告連到同一位收件者。

`contentKey` 每則公告只用一次，以 XOR 包裝是安全的；整份 payload 又有管理端簽章，條目無法被竄改。

### 大小上限

單片封包的上限是 512 bytes（`FRAGMENT_SIZE_THRESHOLD`）。外層 header 加 senderID 共 22 bytes，所以 payload 在 490 bytes 以內就不會切片。

| 情況 | payload | 外層封包 | 片數 |
|---|---|---|---|
| 廣播，內容 300 bytes | 400 | 422 | 1 |
| 純撤回 | 100 | 122 | 1 |
| 定向，4 個收件裝置，內容 169 bytes 以內 | ≤ 490 | ≤ 512 | 1 |
| 定向，5 個收件裝置，內容 300 bytes | 661 | 683 | 2 |

內容上限 300 bytes 加上收件裝置上限 5 個，保證任何公告都不超過 2 片。300 bytes 大約是 100 個中文字。

## 處理規則

### 收到 0x31

適用於所有新版節點，Gateway 也一樣。`SecurityManager.validatePacket` 照既有流程處理封包層級的去重；0x31 不加進 `verifyPacketSignature` 的強制驗簽名單。接著 `PacketProcessor` 交給 0x31 的 handler，依序檢查，任何一步不通過就回傳 `validPacket = false`（不轉送、不呈現）：

1. payload 長度合法：至少 100 bytes；定向 body 的長度與 recipientCount 相符；內容不超過 300 bytes。
2. version 為 `0x01`，kind、level 是已定義的值，keyId 在 App 內建的對照表裡。
3. 外層 senderID 等於 messageId，外層 timestamp 等於 issuedAt。
4. 管理端簽章驗證通過。
5. 時間合理：
   - `issuedAt ≤ now + 10 分鐘`
   - `now ≤ expiresAt + 10 分鐘`
   - `issuedAt < expiresAt ≤ issuedAt + 24 小時`
6. replaces 不等於自己的 messageId。
7. messageId 不在撤回紀錄裡。
8. 去重表：
   - messageId 已存在且已在 mesh 裡 → 重複，不轉送。
   - messageId 已存在但只從 Firestore 收過（Gateway 還在等待注入）→ 取消待注入，標記為已在 mesh 裡，繼續往下，但不再呈現。
   - 不存在 → 寫入去重表，標記為已在 mesh 裡。
9. replaces 不為 0 時，把被取代的 messageId 寫入撤回紀錄，從 sync 集合移除，並更新本機呈現（見撤回與取代）。
10. 加入 sync 集合。
11. 本機呈現：廣播直接呈現；定向則嘗試解密，解得開才呈現，並寫回條（via=ble）。
12. 回傳 `validPacket = true`，交給既有的轉送邏輯。

**一定要先驗簽，再寫去重表與撤回紀錄。** 理由與 `SecurityManager` 只記錄已驗證封包相同：先記下未驗證的封包，攻擊者就能用假封包先佔住一個合法的 messageId，或撤回一則真的公告。

**0x31 的 senderID 不是 peer**（ADR-0011）。把 senderID 當成 peer 的地方都要排除 0x31：

- `PacketProcessor` 依 senderID 建立序列化處理的 actor，只在 peer 斷線時清掉。0x31 要改用一個固定的鍵，否則每則公告都會留下一個永遠不會被清掉的 actor。舊版 App 改不了，每則公告會多留一個，數量有限，接受。
- peer 列表、last-seen、拓撲與除錯畫面。`updatePeerLastSeen` 只更新已存在的 peer，不會因此多出 peer。
- 實地實驗的 log（`ExperimentRecorder`）不記錄 0x31。實地實驗進行中，管理端也不發公告，以免干擾量測（ADR-0001）；寫進管理端的操作手冊。

### 去重表與撤回紀錄

- 去重表：以 messageId 為鍵，保留到 `expiresAt + 10 分鐘`，上限 1000 筆，存在記憶體。不能只靠 `SecurityManager` 的封包去重，因為它只保留幾分鐘，而公告經 sync 補送時可能已經過了好幾個小時。
- 撤回紀錄：被取代的 messageId，保留到取代它的那則公告的 `expiresAt`，上限 1000 筆，存在記憶體。
- 這兩份紀錄在 App 重開後會消失。重開後再收到舊公告，會照第一次收到的流程處理；本機儲存以 messageId 去重，不會重複通知。

### Gossip sync

- 比照 `GossipSyncManager` 保留 Health Report 的 `latestHealthReportBySender`，另開一份以 senderID（即 messageId）為鍵的集合，每則只存一份。要動的地方有 `onPublicPacketSeen`、`handleRequestSync`、`buildGcsPayload` 的候選清單，以及過期清理。
- 只在第 10 步、驗過管理端簽章之後才加入 sync 集合。外層 timestamp 是 issuedAt，sync 層算不出到期時間，所以由 0x31 handler 把 expiresAt 一併交給 sync，sync 層不解析 payload。
- 0x31 沒有 ANNOUNCE，不走 `cachedAnnouncementOfHeldReport` 的先送 ANNOUNCE 邏輯（ADR-0006）。
- 保留到 `expiresAt` 為止；第 5 步的時間檢查保證最多 24 小時。
- 上限 50 則，滿了先移除 expiresAt 最早的。
- 被取代的公告立即移除。
- 定向公告的密文也要同步。中繼看不到內容，但收件者常常正是晚到的那個人。
- 封包是正規化的，GCS 的封包 ID 在所有節點上都一致，不會因為副本來自不同 Gateway 而一再重送。

### 撤回與取代

- **取代**：新公告的 replaces 填被取代的 messageId。收到後，被取代的公告標示為「已更正」並隱藏內容，畫面連到新公告。
- **純撤回**：一律用廣播 kind、空 body、replaces 填被撤回的 messageId，不論原公告是廣播還是定向。內容是空的，加密沒有意義，這樣也不需要收件者的公鑰。被撤回的公告標示為「已撤回」並隱藏內容。
- 取代一則定向公告時，新公告必須是定向的，內容才會加密。
- 管理端要確保新公告的 expiresAt 不早於被取代的那則，撤回紀錄才能撐到原公告過期為止。
- 先收到取代、後收到原公告時，原公告在第 7 步就被丟棄，不轉送也不呈現。
- 原公告已發出的系統通知要一併更新或取消。
- **刪除 Firestore 文件不算撤回。** 公告已經進到 mesh，只有撤回公告能讓中繼停止補送。Gateway 的 listener 收到刪除事件時不做任何事。

### Gateway：從 Firestore 注入 mesh

- listener 放在 `MeshForegroundService`，與送出方向的 `MeshGatewayRuntime` 同一個生命週期（`onCreate` 建立、`onDestroy` 停止），並沿用它的做法：以 `FirebaseAuth.AuthStateListener` 跟著登入狀態，`currentUser` 不為 null 才掛上、登入狀態改變時重新掛上；行程裡沒有初始化 Firebase 時不建立，mesh 照常運作。Kotlin 與 Flutter 共用同一個登入身分，`MeshGatewayRuntime` 已經證實。
- 使用者關閉「背景執行」時前景服務不會啟動，也就沒有 listener（見已知限制）。
- Firebase 程式碼不進 `mesh/`：去重表、撤回紀錄與待注入放在 `mesh/` 這一側，listener 透過類似 `VerifiedHealthReportBridge`、方向相反的 hook 把 `wire` 交進去。
- 查詢：`admin_notices` 中 `expiresAt > 掛上 listener 的時間`。
- 收到新文件時，對 `wire` 執行「收到 0x31」的第 1、2、4–7 步。不相信文件的其他欄位，例如到期時間以 `wire` 裡簽過的為準。外層封包是 Gateway 自己組的，第 3 步不適用。
  - messageId 已在去重表裡、且已在 mesh 裡 → 什麼都不做，已經有人注入了。
  - 否則寫入去重表，標記為「只從 Firestore 收過」；呈現在本機，是收件者就寫回條（via=firestore）；排一個 0–15 秒均勻隨機的注入。
- 注入時間到時，如果還沒有標記為已在 mesh 裡，就依「外層封包」組出封包，廣播出去、加入 sync 集合，並標記為已在 mesh 裡。
- mesh 服務停止時取消所有待注入。重開後 listener 會重新送來所有未到期的公告，Gateway 會再注入一次；封包和之前一模一樣，既有的去重會處理。
- 來自 Firestore 本機快取的文件（`isFromCache`），例如重開時還沒有網路，照樣處理與注入：安全性由簽章保證，不靠文件從哪裡來。App 重開後只放記憶體的 sync 集合已經清空，也能靠快取補回來。
- listener 出錯就會終止，要重新掛上：
  - `RESOURCE_EXHAUSTED`（Spark 額度用完）、`UNAVAILABLE`：從 1 分鐘開始指數退避，最長 30 分鐘。**不可以立即重試**，否則會把剩下的額度燒光，連 Health Report 都讀不到。
  - `PERMISSION_DENIED`：停止，等登入狀態改變再掛上。
- Firestore 的離線快取保持開啟（Android 預設就是開的）。它也不能關：Flutter 與 Kotlin 共用同一個 Firestore 實例（ADR-0009）。

## Firestore

### 集合

| 集合 | 內容 | 誰能讀 | 誰能寫 |
|---|---|---|---|
| `admins/{uid}` | 已存在（ADR-0009）：文件存在就代表是 Administrator | 本人（只能查自己） | 只能從 Console 或 Admin SDK |
| `admin_notices/{messageId}` | `wire`（Bytes）、`expiresAt`、`createdAt`、`createdBy` | 所有登入帳號 | Administrator 新增；不能修改；Administrator 可刪除 |
| `admin_notices/{messageId}/receipts/{uid}` | `deliveredAt`、`readAt`、`via` | Administrator | 本人 |
| `admin_notice_records/{messageId}` | 管理端留存：明文內容、收件者 uid、kind、level、replaces、batchId、操作者 | Administrator | Administrator |
| `reporter_handles/{uid}/installations/{reporterHandle}` | 已存在（MESH_GATEWAY.md 5.3）；新增 `noticePublicKey`（Bytes，32） | 本人、Administrator | 本人 |

文件 ID `messageId` 是 16 個小寫十六進位字元。

`admin_notices` 只放要送上 mesh 的東西，**不能有明文內容，也不能有收件者 uid**：所有 Gateway 都讀得到它，否則定向加密就白做了。

### Security rules 草稿

`isAdmin()`、`isOwner()` 與 `admins/{uid}` 的規則已經在 `firestore.rules` 裡（ADR-0009），以下只列新增與修改的部分。規則測試寫在 `firestore-tests/rules.test.mjs`（見「測試與驗收」）。

```text
match /admin_notices/{messageId} {
  allow read: if request.auth != null;
  allow create: if isAdmin()
                && messageId.matches('^[0-9a-f]{16}$')
                && request.resource.data.keys().hasOnly(['wire', 'expiresAt', 'createdAt', 'createdBy'])
                && request.resource.data.keys().hasAll(['wire', 'expiresAt', 'createdAt', 'createdBy'])
                && request.resource.data.wire is bytes
                && request.resource.data.wire.size() <= 1024
                && request.resource.data.expiresAt is timestamp
                && request.resource.data.expiresAt <= request.time + duration.value(25, 'h')
                && request.resource.data.createdAt == request.time
                && request.resource.data.createdBy == request.auth.uid;
  // messageId 撞號時 set() 會變成 update 而被擋，管理端換一個 messageId 重試。
  allow update: if false;
  allow delete: if isAdmin();

  match /receipts/{uid} {
    allow read: if isAdmin();
    allow create, update: if isOwner(uid)
                          && exists(/databases/$(database)/documents/admin_notices/$(messageId))
                          && request.resource.data.keys().hasOnly(['deliveredAt', 'readAt', 'via'])
                          && request.resource.data.via in ['firestore', 'ble'];
    allow delete: if false;
  }
}

match /admin_notice_records/{messageId} {
  allow read, create: if isAdmin();
  allow update, delete: if false;
}

// 修改：reporter_handles/{uid}/installations/{handle} 的 validInstallation()。
// fields 加上 noticePublicKey，其餘檢查不變：
let fields = ['reporterHandle', 'signingPublicKey', 'noticePublicKey', 'registeredAt'];
// ……
    && data.noticePublicKey is bytes
    && data.noticePublicKey.size() == 32
```

`noticePublicKey` 列為必填（`hasAll`），比照 ADR-0008，實驗期所有裝置一起更新。舊版寫的登記文件沒有這個欄位，下次啟動時會被新版整份覆寫；在那之前，管理端把它視為這台裝置收不到定向公告。

rules 無法驗證 `wire` 的簽章，也無法檢查它和 `expiresAt` 欄位是否一致；這兩件事由用戶端負責。`createdBy` 是共用私鑰之下唯一能追查操作者的依據。

### 回條

- 只有定向公告的收件者寫回條，廣播不寫（Spark 每天只有 20,000 次寫入）。
- 解密成功時寫 `deliveredAt` 與 `via`；在 App 裡打開時寫 `readAt`。時間用手機的時間，不用 `serverTimestamp()`：離線排隊的寫入，伺服器時間是連上網那一刻，不是收到的時間。
- 由 Kotlin 端的 Firestore SDK 寫入。透過 BLE 收到的人沒有網路，寫入會留在 SDK 的離線佇列裡，連上網時自動送出（佇列會寫磁碟，ADR-0009）。回條是本人自己的資料，所以比照 `reporter_handles` 的登記（MESH_GATEWAY.md 7.7）交給離線佇列；Gateway 送出方向把暫存只放在記憶體，是因為那些是別人的回報。
- 寫入後不等伺服器確認：斷線時確認會一直等不到（MESH_GATEWAY.md 7.5）。
- 同一帳號的多台裝置共用一份 `receipts/{uid}`，以最後寫入的為準。
- 回條是收件者自己申報的，rules 不檢查他是不是真的收件者。

## 給管理後台的介面契約

這一節給負責管理後台的組別，可以單獨閱讀；格式細節引用前面各節。

**登入**：使用 Administrator 帳號，授予方式同 MESH_GATEWAY.md 第 8 節。

**私鑰**：見「管理端簽章金鑰」。私鑰檔每次發送前載入，後台不得保存；加解密用純 Dart，64 位元欄位不要用 `ByteData.setUint64`。

**發一則公告**：

1. 操作者選擇 kind、level、內容（UI 即時顯示 byte 數，超過 300 bytes 就不能送出）、expiresAt（最長 24 小時），定向公告再選收件對象。messageId 用安全亂數產生。
2. 定向公告要找出每個收件裝置的 `noticePublicKey`：
   - 指定帳號：讀 `reporter_handles/{uid}/installations` 底下的所有文件。
   - 指定 Reporter Handle（例如在 `mesh_reports` 上看到的）：以 collection group 查詢 `installations` 中 `reporterHandle == handle` 的文件，索引見 MESH_GATEWAY.md 第 8 節。有多個 uid 宣稱同一個 Handle 時，只用 `registeredAt` 最新的那份，並提示操作者（可能是冒領，見已知限制）。
   - 每份有 `noticePublicKey` 的文件是一個收件裝置。找不到任何收件裝置的對象無法送達，要明確提示操作者；`registeredAt` 超過 30 天的顯示警告，但照樣加密。
   - 收件裝置超過 5 個就拆成多則，每則有自己的 messageId，`admin_notice_records` 用同一個 batchId 串起來。
3. 依「線路格式」組 payload 並簽章，定向公告依「定向 body」加密。實作要先對過附錄的 test vectors。
4. 用一次 batch write 同時寫入 `admin_notices/{messageId}`（`wire`、`expiresAt`、`createdAt`、`createdBy`，限制見 rules 草稿）與 `admin_notice_records/{messageId}`。

**取代與撤回**：見「撤回與取代」。新公告的 expiresAt 至少等於被取代的那則；撤回一個拆成多則的批次，每一則都要各發一則撤回。不要用刪除 `admin_notices` 文件代替撤回。

**回條**：定向公告的收件裝置會寫 `admin_notices/{messageId}/receipts/{uid}`（`deliveredAt`、`readAt`、`via`）。時間來自手機時鐘；`via == 'ble'` 代表收件者是經 mesh 收到的。廣播沒有回條。

## 收件端呈現

- 收到的公告存在 Kotlin 端的本機儲存，以 messageId 去重，只在第一次寫入時發通知。定向公告解密後的內容要加密儲存。保留到 `expiresAt` 後 7 天，期間標示為「已過期」。
- 通知由 Kotlin 端發出，每個 level 一個 notification channel：

  | level | channel 重要度 | 行為 |
  |---|---|---|
  | 緊急 | 高 | 聲音與震動；不繞過勿擾模式 |
  | 重要 | 預設 | |
  | 資訊 | 低 | 不出聲 |

- `POST_NOTIFICATIONS` 是選用權限。沒有權限時，首頁要放一張醒目的公告卡片代替通知。
- Flutter 端新增「管理端公告」列表畫面，首頁顯示未讀數量，資料經 bridge 從 Kotlin 取得。建議的介面：EventChannel 推送 `type: "admin_notice"`；MethodChannel 照 `chat_`、`settings_` 的慣例命名，提供 `adminNotice_getAll` 與 `adminNotice_markRead(messageId)`，後者同時寫入 `readAt` 回條。收件者金鑰用的 `adminNotice_getPublicKey(uid)`、`adminNotice_clearKey` 見「收件者加密金鑰」。

## 參數

| 參數 | 值 |
|---|---|
| 內容上限 | 300 bytes |
| 每則收件裝置上限 | 5 |
| 有效期上限（expiresAt − issuedAt） | 24 小時 |
| 時鐘誤差容忍 | 10 分鐘 |
| Gateway 注入延遲 | 0–15 秒，均勻隨機 |
| 去重表、撤回紀錄上限 | 各 1000 筆 |
| sync 集合上限 | 50 則 |
| listener 退避 | 1 分鐘起、指數增加、最長 30 分鐘 |
| 本機保留 | expiresAt 後 7 天 |
| 收件裝置公鑰過期警告 | `registeredAt` 超過 30 天 |

## 已知限制

1. **共用私鑰。** 外洩後、使用者更新 App 之前，偽造的公告都會被接受；mesh 上也分不出是哪位操作者發的。私鑰載入期間放在瀏覽器分頁的記憶體裡：管理後台若有 XSS 或惡意的瀏覽器擴充功能，就能在這段期間讀走它。實驗期刻意接受，正式部署前要重新評估保管方式。
2. **舊版 App 盲目轉送 0x31，包括偽造的。** 不會顯示，到新版節點就會被丟棄。
3. **收件裝置數外露。** 旁人看得到某則是定向公告、有幾個收件裝置、何時出現在 mesh 上；看不到對象與內容。
4. **依賴手機時鐘。** 誤差超過 10 分鐘的手機會把公告誤判為過期或來自未來。
5. **Spark 額度。** 每天 50,000 次讀取，大約只撐得住幾百支 Gateway；額度用完時整個專案的 Firestore 讀取都會失敗。這份額度也要分給管理後台讀 `mesh_reports`，而回條規則裡的 `exists()` 每次寫入都多算一次讀取。每天 20,000 次寫入則由回條、Gateway 寫 `mesh_reports` 與其他寫入共用。正式部署前升級 Blaze。
6. **收件裝置必須在有網路時登入過。** 沒有登記過 `noticePublicKey` 的裝置收不到定向公告。
7. **撤回不保證送達。** 沒收到撤回的人，會一直看到原公告直到它過期。
8. **回條是自我申報的。**
9. **沒有前景服務就沒有 listener。** 使用者關閉「背景執行」（預設開啟）時，這支手機收不到 Firestore 上的公告，只能等別人經 BLE 傳來，也不會當 Gateway 注入。MESH_GATEWAY.md 第 9 節有同一條限制。
10. **以 Reporter Handle 指定時可能被冒領。** 攻擊者把聽到的 Handle 登記在自己的 uid 底下、`registeredAt` 又比較新時，以那個 Handle 指定的定向公告會加密給攻擊者。日後可以比對 `signingPublicKey` 與 `mesh_reports` 原始封包的簽章 key 來排除（MESH_GATEWAY.md 第 9 節）。

## 實作前待驗證

1. **超過 512 bytes 的 0x31 能不能完整走過 gossip sync。** 讀程式的結果是可以：重組後的封包經 `handleMessage` 交給 `onPublicPacketSeen`，sync 回應經 `sendPacketToPeer` 的 `fragmentingSender` 切片。但還沒有任何類型實際這樣跑過，main 上也沒有切片 sync 的測試，實作時寫單元測試確認。
2. **舊版 App 會不會轉送 0x31。** 已從 main 的程式碼確認會：未知類型的廣播封包 `validPacket` 維持 true，交給 `PacketRelayManager` 轉送；`updatePeerLastSeen` 只更新已存在的 peer。實機驗收時順便觀察即可。
3. **Doze 模式與小米、OPPO 等廠商的省電機制下，前景服務與 listener 能不能保持連線。** 併入實機驗收，與 MESH_GATEWAY.md 第 10 節用同一組手機。
4. **App 被系統終止後重開，離線佇列裡的回條什麼時候送出。** 佇列本身會寫磁碟（ADR-0009）；要確認的是沒有 Flutter 畫面時，Kotlin 端有沒有啟動 Firestore 實例把它送出。
5. **iOS bitchat 會不會轉送 0x31。** 不在 v1 範圍內，只記錄結果。

## 測試與驗收

**Kotlin 單元測試**

- 附錄的 test vectors：驗過 V1–V3、拒絕 V4；以 recipient-1、recipient-2 解開 V2，outsider 比對不到任何 tag。
- 「收到 0x31」的每一步各自擋得住；先驗簽才寫去重表與撤回紀錄；去重表的三種情況。
- 撤回與取代：先收到原公告再收到取代，以及反過來，兩種順序都對。
- sync 集合：上限、到期、被取代就移除；超過 512 bytes 的公告經 sync 切片後完整送達（待驗證 1）。
- Gateway 注入：等待期間從 BLE 聽到同一則就不注入；來自快取的文件照樣注入。
- 0x31 不建立 peer、不留下 actor、不進實驗 log。
- 收件者金鑰：uid 改變時重新產生；清除後解不開。

**Dart 測試（管理後台）**

- 以相同輸入產生逐位元組相同的 V1–V3，在 Web 上執行。

**規則測試**（`firestore-tests/rules.test.mjs`）

- `admin_notices`：只有 Administrator 能建立與刪除；欄位、`createdBy`、`createdAt`、`expiresAt` 上限、messageId 格式；不能 update。
- `receipts`：只有本人能寫自己的；`via` 只能是兩個值之一；只有 Administrator 能讀。
- `admin_notice_records`：只有 Administrator 能讀與建立，不能修改或刪除。
- `installations`：缺少 `noticePublicKey` 或長度不對時被擋。

**實機驗收**（三支手機：A 無網路的收件者、B 無網路的中繼、C 有網路的 Gateway；可以與 MESH_GATEWAY.md 第 10 節一起做）

1. 發一則廣播 → C 從 Firestore 收到並注入，A 經 B 收到並跳出通知。
2. 發定向公告給 A 的帳號 → A 解得開，B 只轉送不顯示；A 連上網路後出現 `via == 'ble'` 的回條。
3. 撤回第 1 則 → A 上標示「已撤回」，通知被更新或取消。
4. 公告發出之後才讓 A 進入 B 的範圍 → A 經 gossip sync 收到。
5. C 滑掉 App 畫面（服務仍在）→ 仍會注入。
6. C 重開 App → 不會重複通知。

## 實作順序

建議拆成五個 PR，依序合併：

1. **Firestore 規則**：`admin_notices`、`receipts`、`admin_notice_records`，以及規則測試。合併後就可以通知管理後台那組依介面契約開工，或改用 Python 工具（見開頭的狀態）。
2. **收件者金鑰**：Kotlin 產生與保存 X25519 金鑰、`adminNotice_getPublicKey`／`adminNotice_clearKey`、Flutter 登記時寫入 `noticePublicKey`，連同 `installations` 規則的修改。規則與登記放在同一個 PR，必填欄位才不會擋掉還沒更新的登記。
3. **協定層**：`MessageType.ADMIN_NOTICE`、解析與驗簽、處理規則、去重表與撤回紀錄、gossip sync、`PacketProcessor` 的 actor 鍵、實驗 log 排除；test vectors 與切片 sync 的單元測試。
4. **Gateway 注入與回條**：listener、隨機延遲注入、回條。CLAUDE.md 與 AGENTS.md 的架構限制第 5 條同步改寫（ADR-0011）。
5. **收件端呈現**：本機儲存、notification channel、Flutter 列表畫面與首頁未讀數。`PRIVACY_POLICY.md` 新增一節，說明 `noticePublicKey` 與回條，包括 `via == 'ble'` 會透露收件者當時沒有網路。

## 附錄：test vectors

由 `tools/admin-notice/gen_test_vectors.py` 產生（需要 `pip install cryptography`）。所有金鑰都由固定字串的 SHA-256 推出，**只能用於測試**。Kotlin 與 Dart 的實作都要能：

- 驗過 V1、V2、V3 的簽章，並拒絕 V4。
- 用 recipient-1 與 recipient-2 的私鑰解開 V2；用 outsider 的私鑰比對不到任何 tag。
- 管理端用相同的輸入，產生逐位元組相同的 V1、V2、V3。

### 共用金鑰

```text
admin Ed25519 seed: 1400079ad9d2b9d0728405120c081de046ea67a696bbbc1575b97ba7d8d03085
admin Ed25519 public (keyId 0x01): 10f835a2f82b877a2c1c705ef3c71d3640a40b4e39f6ca4197c17eaefb05a176
recipient-1 X25519 private: 543430b3141351317d1fc752adafabb51eea760014c56ef649db958aee664b12
recipient-1 X25519 public: b4177f14809dedec48eb6fc12446868827c750a0733e4c9683f729711941ea4b
recipient-2 X25519 private: 9ca79b4e47da69ee9e5f577e7354942ddae23de0df9bac70a03fc397827c1473
recipient-2 X25519 public: 7bd70cbf387e97a5d30a57fb0e7e31ac671ecd447d8f0f49b6b5c5eb85ba0d1e
outsider X25519 private（不是收件者）: 25c0ec1c0a16c67a57e0bd636008e61851a10ff8f27ebe488fd07cb570ef5ce0
```

### V1 廣播（緊急）

```text
messageId: a1b2c3d4e5f60718
issuedAt: 1792627200000
expiresAt: 1792648800000
content (UTF-8): 土石流警戒：請立即撤離至大同國小避難所
content bytes: 57
payload bytes: 157
payload:
  01010103a1b2c3d4e5f60718000001a160e85000000001a16231e70000000000
  00000000e59c9fe79fb3e6b581e8ada6e68892efbc9ae8ab8be7ab8be58db3e6
  92a4e99ba2e887b3e5a4a7e5908ce59c8be5b08fe981bfe99ba3e689805c770d
  5b6d3a8d4165dd74006650f7c96b1fab54ec1340438ad884db367d8a7f2d0288
  9bc878922000ad2616d9dbaa019eeaeeecc4af17d7813bb76eb8a5a60b
```

### V2 組播（重要，2 位收件者）

```text
messageId: 0f1e2d3c4b5a6978
issuedAt: 1792627200000
expiresAt: 1792634400000
content (UTF-8): 救援人員約 10 分鐘內抵達，請留在原地
content bytes: 52
ephemeral X25519 private: 72e87dd33fc95391ead3064bcd6040ee1a5a166fe577bb1a2f6392a0c2500f9e
ephemeral X25519 public: a722369abb0be24a97efa8dba00415b782bd5cd532f5e8f95987deb52161d900
contentKey: 5a9af80bf6d4c7425057634d4e7b62fc0d6231ffc5c7979a68593d895f2fcc7b
nonce: b843ea2414803cdaa677b432
recipient-1 shared: d34a603d568c019c3b14e882f037a75369c1a4e394ac00d7676ae3145afd9513
recipient-1 tag: b043ecb010281c9b
recipient-1 kek: 68ce45a2e46107fa604f01c87171dd7d9e1af87e7ef008697829ccac71817de5
recipient-1 wrappedKey: 3254bda912b5c0b8301862853f0abf819378c981bb379ff31070f1252eaeb19e
recipient-2 tag: cd088fb1bd9143ce
recipient-2 wrappedKey: 43fb345512ecf908e41ec2e45803d25bea94f03a26de91c2192764c31b4e8b6e
payload bytes: 293
payload:
  010201020f1e2d3c4b5a6978000001a160e85000000001a161562d0000000000
  00000000a722369abb0be24a97efa8dba00415b782bd5cd532f5e8f95987deb5
  2161d90002b043ecb010281c9b3254bda912b5c0b8301862853f0abf819378c9
  81bb379ff31070f1252eaeb19ecd088fb1bd9143ce43fb345512ecf908e41ec2
  e45803d25bea94f03a26de91c2192764c31b4e8b6eb843ea2414803cdaa677b4
  324f0050264e816da8b115eab31257532f764ffd206d987e2c08186fe49189cc
  8f9c68eb3b19dd9a3aef555d8a1c7a5b7237a4f26a436230b849125eb14fb732
  fed8ea7eb2e6449ee9b545e158b8a68e24b6e4cc687ed7268cb41dfd34f59918
  328a56cbb2237ecacd35555446cb428df5e6fc4b95b6590d8f0342f1a3c729c0
  f03e58540d
```

### V3 撤回 V1（不帶內容的取代）

```text
messageId: 5566778899aabbcc
issuedAt: 1792627800000
expiresAt: 1792648800000
replaces: a1b2c3d4e5f60718
payload bytes: 100
payload:
  010101035566778899aabbcc000001a160f177c0000001a16231e700a1b2c3d4
  e5f60718906c626ca840e351bfaa44b6778bc7ca50e99aa5470cb920602c403d
  45763debcff0ff88c8cd9d7db40447416a64671333382ec93cd5f3fda36fcbe1
  f5b54301
```

### V4 竄改 V1 的 level（0x03 → 0x01），驗簽必須失敗

```text
payload:
  01010101a1b2c3d4e5f60718000001a160e85000000001a16231e70000000000
  00000000e59c9fe79fb3e6b581e8ada6e68892efbc9ae8ab8be7ab8be58db3e6
  92a4e99ba2e887b3e5a4a7e5908ce59c8be5b08fe981bfe99ba3e689805c770d
  5b6d3a8d4165dd74006650f7c96b1fab54ec1340438ad884db367d8a7f2d0288
  9bc878922000ad2616d9dbaa019eeaeeecc4af17d7813bb76eb8a5a60b
```
