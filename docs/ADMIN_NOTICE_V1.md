# 管理端公告 v1（ADMIN_NOTICE）

> 狀態：已實作（#135–#143），待實機驗收（#144）。Firestore 規則（`admin_notices`、`admin_notice_records`、回條的 `receipts`）與 Python 發送工具（#135 廣播；#141 定向公告；#139 更正與撤回）。App 端：Gateway 的 listener、`AdminNoticeInbox` 的驗證與去重、本機儲存與通知（#136）；mesh 收件與 Gateway 注入（#137）；App 內的公告列表與首頁未讀數（#142）；gossip sync（#138）；定向公告的解密與呈現（#141）；取代與撤回（#139）；定向公告的送達與已讀回條（#143）。管理後台的發送頁面與 Dart 加解密是否由另一組實作，確認中；若不接，改由本專案以 `tools/admin-notice/` 的 Python 工具發送（[操作手冊](../tools/admin-notice/README.md)）。
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
- 私鑰檔是一行 64 個小寫十六進位字元，即 Ed25519 的 32 bytes seed（RFC 8032 的 private key），由 `tools/admin-notice/admin_notice_tool.py keygen` 產生。管理後台以純 Dart 載入，例如 `package:cryptography` 的 `newKeyPairFromSeed`。
- App 內建 `keyId → 32 bytes 公鑰` 的對照表，來源是 [`tools/admin-notice/admin_public_keys.json`](../tools/admin-notice/admin_public_keys.json)。`0x00` 保留不用。
- 換 key：先發一版同時內建新舊兩把的 App，多數使用者更新後管理端改用新 key，再發一版移除舊 key。
- 私鑰外洩：發一版移除該 key 的 App。使用者更新之前，偽造的公告仍會被接受（見已知限制）。
- 私鑰檔在操作者之間的分發與備份是手動作業，寫在管理端的[操作手冊](../tools/admin-notice/README.md)裡。

### 收件者加密金鑰

- 每次安裝的 App 在每次登入時產生一組 X25519 金鑰，綁定當時登入的 uid。私鑰存在 Kotlin 端的 EncryptedSharedPreferences，解密才能在背景進行。
- 公鑰登記在 `reporter_handles/{uid}/installations/{reporterHandle}` 的 `noticePublicKey`，與 Reporter Handle、簽章公鑰同一份文件，沿用 [MESH_GATEWAY.md](MESH_GATEWAY.md) 7.7 的登記：App 啟動時與登入成功後由 Flutter 整份 `set` 一次。公鑰經新增的 bridge 方法 `adminNotice_getPublicKey(uid)` 從 Kotlin 取得；傳入的 uid 與私鑰綁定的不同時，Kotlin 先刪除舊私鑰再產生新的。一個帳號登記過幾台裝置，就有幾把公鑰。
- bridge 的回傳（#140 定案）：`adminNotice_getPublicKey` 回 32 bytes（Dart 的 `Uint8List`）；`adminNotice_clearKey` 在私鑰已從磁碟刪除後回 null。加密儲存開不了或寫不進去時兩者都回 `KEY_STORE_UNAVAILABLE`，uid 缺少或為空字串時回 `INVALID_ARGUMENT`。Kotlin 端是 `identity/AdminNoticeRecipientKeyStore`，私鑰不離開它：協定層以 `publicKey()` 取得 `R`、以 `agree(ephemeralPublicKey)` 取得 `shared`，沒有金鑰或結果全為 0 時回 null。
- 登出時 Flutter 呼叫 `adminNotice_clearKey`，要求 Kotlin 刪除私鑰；刪不掉只留 log、照樣登出，下一個帳號登入時 Kotlin 會先刪掉它。緊急清除在原生清除之後也呼叫它，刪不掉就中止，讓使用者再試一次。登記文件照 MESH_GATEWAY.md 5.3 不刪除：同一支手機改登入另一個帳號後，前一個帳號底下那份文件留著的是私鑰已刪除的公鑰，加密給它不會外洩內容，只會佔掉一個收件裝置的名額。
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

#141 定下的細節：

- Inbox 經注入的 port `AdminNoticeRecipientKey`（`publicKey()` 取得 `R`、`agree(ephemeralPublicKey)` 取得 `shared`）解密，私鑰不離開 `AdminNoticeRecipientKeyStore`。正式環境的 `StoredAdminNoticeRecipientKey` 每次都向 `AdminNoticeRecipientKeyStore.getInstance` 取用，與 Flutter bridge 是同一個實例：登出（`adminNotice_clearKey`）之後收到的定向公告立刻不再呈現。它不在建構時開 keystore（Inbox 在主執行緒建立）。
- 解密是第 11 步（Firestore 那條路是「呈現在本機」那一步），排在驗簽、去重表與轉送的決定之後，只決定呈現與否。沒有金鑰、金鑰讀不到（例外）、tag 比對不到、GCM 失敗，一律當成不是收件者：照常轉送與注入。例外若一路傳到 mesh，會被當成「不轉送」，而這則已記為「已在 mesh 裡」，之後的副本也不會再轉送，所以 Inbox 一定攔下。
- tag 以 `MessageDigest.isEqual` 比對每一個條目，比對到也不提早結束；有兩個條目相符時用第一個。
- 每則公告只呈現一次，由第一份收到的副本決定（去重表的三種情況）。呈現時帶著那份副本的來源（`ReceivedAdminNotice.source`：`BACKEND` 或 `MESH`），#143 依它寫回條的 `via`（`firestore`、`ble`）。第一份解不開（例如當時沒有登入），之後的副本不會再試。
- 解出空內容的定向公告不呈現，與空內容的廣播相同（純撤回一律用廣播 kind，發送工具也不簽空內容的定向公告）。

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

1. payload 長度合法：至少 100 bytes；定向 body 的長度與 recipientCount（1–5）相符；內容不超過 300 bytes；廣播 body 只有 replaces 不為 0 時才可以是空的；messageId 不全為 0（全為 0 保留給「沒有 replaces」）。
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

#137 定下的細節：

- 第 3 步只比對 senderID 與 timestamp。外層其他欄位（recipient、裝置簽章、route、severity、version）Inbox 不看，轉送時一律換成正規化的外層封包（`AdminNoticeTraffic.normalizedForRelay`），TTL 與收到的 payload 編碼不變。這些欄位都不在 `PacketIdUtil` 的封包 ID 裡，`SecurityManager` 又在 Inbox 之前就記下封包 ID：如果帶著它們的副本被擋下，攻擊者先送一份加了 recipient 的真公告就能讓後到的正規副本被當成重複；如果原樣轉送，就能把公告擋在指定的收件者、或用 route 導向指定的路徑。
- `SecurityManager` 在 Inbox 驗簽之前就記下 0x31 的封包 ID，這不違反「先驗簽才記錄」：管理端簽章在 payload 裡，偽造的副本封包 ID 一定和真的不同，佔不住真公告。
- 去重表的「只從 Firestore 收過」改為「已在 mesh 裡」時，`Inbox.markInMesh` 一併取消待注入；mesh 聽到的與 Gateway 注入的公告都經過這裡，#138 在這裡加入 sync 集合（見「Gossip sync」的實作）。
- `onMeshPacket` 回傳的 `relay` 就是 `validPacket`。沒有安裝 Inbox、或處理時丟出例外，`AdminNoticeBridge.deliverFromMesh` 一律回傳不轉送。BLE mesh 與 Wi-Fi Aware 的 `MeshCore` 交給同一個 Inbox。

**0x31 的 senderID 不是 peer**（ADR-0011）。把 senderID 當成 peer 的地方都要排除 0x31：

- `PacketProcessor` 依 senderID 建立序列化處理的 actor，只在 peer 斷線時清掉。0x31 要改用一個固定的鍵，否則每則公告都會留下一個永遠不會被清掉的 actor。舊版 App 改不了，每則公告會多留一個，數量有限，接受。
- peer 列表、last-seen、拓撲與除錯畫面。`updatePeerLastSeen` 只更新已存在的 peer，不會因此多出 peer。
- 實地實驗的 log（`ExperimentRecorder`）不記錄 0x31。實地實驗進行中，管理端也不發公告，以免干擾量測（ADR-0001）；寫進管理端的操作手冊。

實作（#137）：判斷集中在 `mesh/AdminNoticeTraffic.carriesAdminNotice`，0x31 與它的切片（FRAGMENT 的 originalType 是 0x31）都算，因為切片的 senderID 同樣是 messageId。

- actor：兩者都排進同一個固定的 actor（`admin-notice`，不是十六進位，不會撞到 peerID）。
- last-seen：不呼叫 `updatePeerLastSeen`，`PacketProcessor` 的 verbose 收件 log 也不記。
- 除錯畫面：`DebugSettingsManager.logIncoming` 照樣算進送來的鏈路，不算成某個 peer 的流量，也不發 `PacketActivity`。拓撲（`MeshGraphService`）只從 ANNOUNCE 更新，本來就不受影響。
- 實驗 log：插入點照舊原樣交資料，由 debug build 寫 `exp.csv` 的 `ExperimentEventRecorder` 排除 RX、DUP、TX／RELAY、SYNC、QFULL 各列。
- Flutter：0x31 不經過 `MessageHandler`，不會以 `type: "packet"` 推給 Flutter。

### 去重表與撤回紀錄

- 去重表：以 messageId 為鍵，保留到 `expiresAt + 10 分鐘`，上限 1000 筆，存在記憶體。不能只靠 `SecurityManager` 的封包去重，因為它只保留幾分鐘，而公告經 sync 補送時可能已經過了好幾個小時。
- 撤回紀錄：被取代的 messageId，保留到取代它的那則公告的 `expiresAt` 加 10 分鐘，上限 1000 筆，滿了先丟最早到期的，存在記憶體。多出的 10 分鐘是時鐘誤差容忍（#139 定案）：節點在原公告 `expiresAt` 之後 10 分鐘內仍會收下它，取代它的那則又不會比它早到期，只保留到 `expiresAt` 的話，先收到取代的手機會在這段期間把晚到的原公告當成新公告。
- 這兩份紀錄在 App 重開後會消失。重開後再收到舊公告，會照第一次收到的流程處理；本機儲存以 messageId 去重，不會重複通知。已更正、已撤回的狀態存在本機儲存裡，重開後再收到原公告也不會退回「有效」。
  - 例外（#139）：重開前先收到取代、原公告在第 7 步被丟棄、從沒存進本機儲存的手機，重開後若先收到原公告，會把它當成新公告呈現並通知，等取代到了才標示並收回通知。listener 重新掛上時會一次送來兩者，這段時間通常很短；只從 mesh 收到原公告、取代卻沒再傳來的話，原公告就一直有效到它過期，與已知限制 7 相同。

### Gossip sync

- 比照 `GossipSyncManager` 保留 Health Report 的 `latestHealthReportBySender`，另開一份以 senderID（即 messageId）為鍵的集合，每則只存一份。要動的地方有 `onPublicPacketSeen`、`handleRequestSync`、`buildGcsPayload` 的候選清單，以及過期清理。
- 只在第 10 步、驗過管理端簽章之後才加入 sync 集合。外層 timestamp 是 issuedAt，sync 層算不出到期時間，所以由 0x31 handler 把 expiresAt 一併交給 sync，sync 層不解析 payload。
- 0x31 沒有 ANNOUNCE，不走 `cachedAnnouncementOfHeldReport` 的先送 ANNOUNCE 邏輯（ADR-0006）。
- 保留到 `expiresAt` 為止；第 5 步的時間檢查保證最多 24 小時。
- 上限 50 則，滿了先移除 expiresAt 最早的。
- 被取代的公告立即移除。
- 定向公告的密文也要同步。中繼看不到內容，但收件者常常正是晚到的那個人。
- 封包是正規化的，GCS 的封包 ID 在所有節點上都一致，不會因為副本來自不同 Gateway 而一再重送。
- 實作（#138）：
  - `GossipSyncManager.onAdminNoticeSeen(packet, expiresAtMs)` 是 0x31 唯一的入口，`onPublicPacketSeen` 照舊不收 0x31，所以沒驗過簽章的副本進不來。`removeAdminNotice(messageId)` 移除被取代的公告（#139 在第 9 步呼叫）。expiresAt 到了、定期清理（`CLEANUP_INTERVAL_MS`，1 分鐘）還沒清掉的，不送也不宣告；交進來時已到期的不收。
  - sync 回應依序送 ANNOUNCE、Health Report、公告、公開訊息；公告前面不送任何東西。
  - GCS 候選清單照既有規則依 timestamp（公告是 issuedAt）由新到舊取，公告不另外優先。公開訊息很多時，舊公告可能擠不進自己的 filter，鄰居每輪就會再送一次；收到的 Inbox 視為重複、不轉送，只多花頻寬，不會漏送。
  - Inbox 交給 sync 的 port 是 `AdminNoticeSyncSet`（`add(packet, expiresAtMs)`、`remove(messageId)`），屬於正在跑的 mesh 服務，生命週期與注入出口相同：`BluetoothMeshService` 啟動成功後經 `AdminNoticeBridge.attachMesh(injector, syncSet)` 一起掛上，`stopServices` 與關閉 BLE 傳輸時 `detachMesh` 一起卸下，舊實例較晚才卸下時不影響新實例。
  - 這個 `GossipSyncManager` 與 Wi-Fi Aware 的 `MeshCore` 共用（`MeshServiceHolder`），Wi-Fi Aware 聽到的公告也經同一個 Inbox 進來，兩邊的 peer 都補得到。除錯設定把 BLE 傳輸關掉時 mesh 服務不會掛上，與注入一樣沒有 sync。
  - mesh 服務換新的實例：Inbox 與行程同壽，已在 mesh 裡的公告不會重新注入，新實例的 sync 集合卻是空的。所以 Inbox 另外留一份還沒過期、已在 mesh 裡的公告（正規化的外層封包與 expiresAt，上限同 sync 集合 50 則，滿了丟 expiresAt 最早的），新的 sync 集合掛上時一次補給它。這份只放記憶體，App 重開後與 sync 集合一起清空，要等 Firestore 的快取或鄰居的 sync 補回。被取代的公告在第 9 步從這份與 port 一起移除（#139）。
  - 在時鐘誤差容忍內收下、但已過 expiresAt 的公告照常轉送，不加入 sync 集合。

### 撤回與取代

- **取代**：新公告的 replaces 填被取代的 messageId。收到後，被取代的公告標示為「已更正」並隱藏內容，畫面連到新公告。
- **純撤回**：一律用廣播 kind、空 body、replaces 填被撤回的 messageId，不論原公告是廣播還是定向。內容是空的，加密沒有意義，這樣也不需要收件者的公鑰。被撤回的公告標示為「已撤回」並隱藏內容。
- 取代一則定向公告時，新公告必須是定向的，內容才會加密。
- 管理端要確保新公告的 expiresAt 不早於被取代的那則，撤回紀錄才能撐到原公告過期為止。
- 先收到取代、後收到原公告時，原公告在第 7 步就被丟棄，不轉送也不呈現。
- 原公告已發出的系統通知要一併更新或取消。
- **刪除 Firestore 文件不算撤回。** 公告已經進到 mesh，只有撤回公告能讓中繼停止補送。Gateway 的 listener 收到刪除事件時不做任何事。
- 實作（#139）：
  - 第 7 步與第 9 步兩個來源都適用。第 7 步丟棄的公告，`AdminNoticeInbox` 回 `Rejected(REVOKED)`：不轉送、不注入、不呈現、不加入 sync 集合。第 9 步只在驗過簽章、第一次收到時做一次（重複的副本、從 Firestore 收過後又從 mesh 聽到的都不再做）：寫入撤回紀錄，取消被取代那則的待注入，從 sync 集合（`AdminNoticeSyncSet.remove`）與 Inbox 給新 mesh 服務的那份移除，再交給本機呈現（`AdminNoticePresenter.correct` 或 `withdraw`），最後才呈現新公告本身。
  - 什麼是純撤回看公告本身：廣播 kind、空 body、replaces 不為 0（`AdminNoticePayload.isPureRevoke`）。其他帶 replaces 的都是更正，包括這台裝置解不開的定向更正：原公告照樣標示「已更正」，新公告照常轉送但不呈現。
  - 本機儲存（`AdminNoticeStore.markCorrected`、`markWithdrawn`）：只有「有效」的公告能標成「已更正」；「已撤回」是最終狀態，已更正的仍可再撤回。被取代的公告連內容一起從儲存清掉，不只是畫面不顯示：Administrator 收回的內容不該留在手機上，定向公告解密後的內容更是如此；明文留存在 `admin_notice_records`，列表也不再顯示它。bridge 傳給 Dart 的 `content` 因此是空字串。`insertIfAbsent` 不覆寫，重開後再收到原公告也不會把狀態或內容帶回來。
  - 一則公告被多則更正（定向更正拆成多則，每則都帶同一個 replaces；或更正只加密給別的裝置）時，`replacedBy` 先連到先收到的那則；它不在本機儲存裡（這台裝置解不開）時，之後收到的更正會把連結移過去，所以只要有一則讀得到，畫面就連得到它。
  - 通知：原公告的通知以 messageId 為 tag 取消（`AdminNoticeNotifier.cancel`），撤回與更正都一樣，存不進儲存時也照樣取消。更正不改寫舊通知，而是新公告照第一次收到的流程，以自己的 messageId 通知、依它的 level 再響一次：要使用者照做的事已經變了；改寫舊通知的話，tag 與新公告對不上，下一次更正就找不到它。
  - 發送工具（`tools/admin-notice/`）：`send --replaces <messageId>` 發更正，`revoke <messageId>` 發純撤回，`revoke --batch <batchId>` 對批次裡的每一則各發一則撤回、一次 commit 寫入。都先以 Administrator 讀 `admin_notice_records` 檢查：被取代的那則要存在、不是撤回、還沒被取代過（App 上「已撤回」是最終狀態，「已更正」只連到一則，要再改的是取代它的那則）；更正的 expiresAt 不早於它；定向公告只能用定向公告更正。純撤回的 level 沿用原公告，與原公告同時到期；原公告已經或快要過期時至少保留 1 小時，讓列表裡還留著它的手機（保留到過期後 7 天）也收得到。更正拆成多則的批次中的一則時，工具提醒操作者其他則不受影響，要整批收回就用 `revoke --batch` 再重發。

### Gateway：從 Firestore 注入 mesh

- listener 放在 `MeshForegroundService`，與送出方向的 `MeshGatewayRuntime` 同一個生命週期（`onCreate` 建立、`onDestroy` 停止），並沿用它的做法：以 `FirebaseAuth.AuthStateListener` 跟著登入狀態，`currentUser` 不為 null 才掛上、登入狀態改變時重新掛上；行程裡沒有初始化 Firebase 時不建立，mesh 照常運作。Kotlin 與 Flutter 共用同一個登入身分，`MeshGatewayRuntime` 已經證實。
- 使用者關閉「背景執行」時前景服務不會啟動，也就沒有 listener（見已知限制）。
- Firebase 程式碼不進 `mesh/`：去重表、撤回紀錄與待注入放在不依賴 Firebase 的 `adminnotice/` 套件（`AdminNoticeInbox`），listener 透過 `AdminNoticeBridge`（類似 `VerifiedHealthReportBridge`、方向相反的 hook）把 `wire` 交進去。Inbox 由 `BitchatApplication.onCreate` 建立並裝進 `AdminNoticeBridge`，與行程同壽：去重表要撐過 mesh service 換新的實例，mesh 收件在前景服務沒跑時（關閉背景執行）也要用到它。listener 只跟著前景服務。
- 查詢：`admin_notices` 中 `expiresAt > 掛上 listener 的時間`。
- 收到新文件時，對 `wire` 執行「收到 0x31」的第 1、2、4–7 步。不相信文件的其他欄位，例如到期時間以 `wire` 裡簽過的為準。外層封包是 Gateway 自己組的，第 3 步不適用。
  - messageId 已在去重表裡、且已在 mesh 裡 → 什麼都不做，已經有人注入了。
  - messageId 已在去重表裡、只從 Firestore 收過（例如登入狀態改變後重新掛上，listener 又送來同一份）→ 什麼都不做，呈現與注入在第一次就排好了。
  - 否則寫入去重表，標記為「只從 Firestore 收過」；呈現在本機，是收件者就寫回條（via=firestore）；排一個 0–15 秒均勻隨機的注入。
- 注入時間到時，如果還沒有標記為已在 mesh 裡，就依「外層封包」組出封包，廣播出去、加入 sync 集合，並標記為已在 mesh 裡。
- mesh 服務停止時取消所有待注入。重開後 listener 會重新送來所有未到期的公告，Gateway 會再注入一次；封包和之前一模一樣，既有的去重會處理。
- 實作（#137）：
  - 延遲由行程層級的單一 daemon 執行緒排程（`AdminNotices.install`），延遲與亂數都以 port 注入 Inbox，測試用假的。
  - `BluetoothMeshService` 啟動成功後經 `AdminNoticeBridge.attachMesh` 成為注入出口；`stopServices` 與關閉 BLE 傳輸時 `detachMesh`，Inbox 隨即取消所有待注入。舊實例較晚才停止時，不會取消新實例的待注入。
  - 注入的封包不簽章、不加 route，經 `broadcastRoutedPacket` 送出（BLE 與橋接的傳輸）。
  - 時間到時沒有 mesh 服務、或交不出去，這次注入就放棄，公告仍是「只從 Firestore 收過」：期間從 BLE 聽到，照「收到 0x31」轉送、不再呈現。
  - Inbox 與行程同壽（#136），去重表會撐過 mesh 服務重開，所以上一段的「再注入一次」只適用於還沒進 mesh 的公告：「只從 Firestore 收過」、待注入已被取消或放棄的公告，再從 Firestore 收到時重新排注入，不再呈現。已在 mesh 裡的公告不會重新注入；mesh 服務換新的實例後，由 Inbox 把它們補回新的 sync 集合（#138，見「Gossip sync」的實作）。
- 來自 Firestore 本機快取的文件（`isFromCache`），例如重開時還沒有網路，照樣處理與注入：安全性由簽章保證，不靠文件從哪裡來。App 重開後只放記憶體的 sync 集合已經清空，也能靠快取補回來。
- listener 出錯就會終止，要重新掛上：
  - `RESOURCE_EXHAUSTED`（Spark 額度用完）、`UNAVAILABLE`：從 1 分鐘開始指數退避，最長 30 分鐘。**不可以立即重試**，否則會把剩下的額度燒光，連 Health Report 都讀不到。其他錯誤碼也照這樣退避。
  - `PERMISSION_DENIED`：停止，等登入狀態改變再掛上。
  - 從伺服器（不是本機快取）收到 snapshot，代表 Firestore 又連得上，等待時間才歸回 1 分鐘。listener 因此開啟 metadata 變化（`MetadataChanges.INCLUDE`），從快取切到伺服器的那一刻才看得到；這不多花讀取。
  - 換成另一個帳號登入、或登出後再登入，都立即重新掛上，等待時間從 1 分鐘重新算；同一個帳號重複回報不算改變。
  - 退避與登入狀態的判斷在不依賴 Firebase 的 `AdminNoticeSubscription`（排程與時鐘都是注入的），Firestore 的部分只有 `FirestoreAdminNoticeFeed`。
- Firestore 的離線快取保持開啟（Android 預設就是開的）。它也不能關：Flutter 與 Kotlin 共用同一個 Firestore 實例（ADR-0009）。

## Firestore

### 集合

| 集合 | 內容 | 誰能讀 | 誰能寫 |
|---|---|---|---|
| `admins/{uid}` | 已存在（ADR-0009）：文件存在就代表是 Administrator | 本人（只能查自己） | 只能從 Console 或 Admin SDK |
| `admin_notices/{messageId}` | `wire`（Bytes）、`expiresAt`、`createdAt`、`createdBy` | 所有登入帳號 | Administrator 新增；不能修改；Administrator 可刪除 |
| `admin_notices/{messageId}/receipts/{uid}` | `deliveredAt`、`readAt`、`via` | Administrator | 本人 |
| `admin_notice_records/{messageId}` | 管理端留存：明文內容、收件者 uid、kind、level、replaces、batchId、操作者（欄位見下） | Administrator | Administrator 新增；不能修改或刪除 |
| `reporter_handles/{uid}/installations/{reporterHandle}` | 已存在（MESH_GATEWAY.md 5.3）；新增 `noticePublicKey`（Bytes，32） | 本人、Administrator | 本人 |

文件 ID `messageId` 是 16 個小寫十六進位字元。

`admin_notices` 只放要送上 mesh 的東西，**不能有明文內容，也不能有收件者 uid**：所有 Gateway 都讀得到它，否則定向加密就白做了。

`admin_notice_records` 的欄位如下。rules 不檢查這份文件的欄位，但發送工具與管理後台都照這份寫，事後才查得起來：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `kind` | string | `broadcast` 或 `targeted` |
| `level` | string | `info`、`important` 或 `urgent` |
| `content` | string | 明文內容；純撤回是空字串 |
| `issuedAt`、`expiresAt` | timestamp | 與 `wire` 裡簽過的相同 |
| `replaces` | string 或 null | 被取代的 messageId（16 個小寫十六進位字元）；沒有就是 null |
| `batchId` | string | 拆成多則的定向公告共用同一個值，即第一則的 messageId；沒有拆的公告填自己的 messageId |
| `createdBy` | string | 操作者的 uid，與 `admin_notices` 的 `createdBy` 相同 |
| `createdAt` | timestamp | 伺服器時間 |

定向公告另外記錄收件對象（#141）：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `recipientUids` | array of string | 操作者指定的帳號（uid），依指定的順序；同一批的每一則都一樣 |
| `recipientHandles` | array of string | 操作者指定的 Reporter Handle；同一批的每一則都一樣 |
| `recipientCount` | integer | 這一則加密給的收件裝置數，即 `wire` 的 recipientCount |
| `recipientDevices` | array of map | 這一則加密給的每台收件裝置：`uid`、`reporterHandle`（登記文件的路徑）與 `noticePublicKey`（當時用的公鑰，Bytes）。順序與 `wire` 裡的條目無關 |

收件裝置以 `uid` + `reporterHandle` 記錄，回條（`receipts/{uid}`）與登記文件都對得起來；`noticePublicKey` 讓事後查得出當時加密給的是哪一把，那支手機之後換過帳號也一樣。

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
    function validReceipt() {
      let data = request.resource.data;
      return data.keys().hasOnly(['deliveredAt', 'readAt', 'via'])
          && data.keys().hasAll(['deliveredAt', 'via'])
          && data.deliveredAt is timestamp
          && data.via in ['firestore', 'ble']
          && (!('readAt' in data) || data.readAt is timestamp);
    }

    allow read: if isAdmin();
    allow create, update: if isOwner(uid)
                          && exists(/databases/$(database)/documents/admin_notices/$(messageId))
                          && validReceipt();
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

#143 定下的細節：

- 回條 port `AdminNoticeReceipts`（`adminnotice/`，不依賴 Firebase）：`delivered(messageId, via, deliveredAtMs)` 與 `read(messageId, readAtMs)`，兩者都必須立即返回。Firestore 實作是 `gateway/FirestoreAdminNoticeReceipts`，由 `BitchatApplication` 交給 `AdminNotices.install`，`adminnotice/` 因此不依賴 `gateway/`。
- 送達：`LocalAdminNoticePresenter` 在定向公告**第一次存進本機儲存**時呼叫 `delivered`，時間與 `receivedAtMs` 相同，`via` 來自 `ReceivedAdminNotice.source`（`BACKEND` → `firestore`、`MESH` → `ble`）。Inbox 只在解得開時才呈現，所以廣播、不是收件者都不會走到這裡。以本機儲存而不是每次呈現為準：App 重開後去重表是空的，Gateway 的 listener 又會把每則未過期的公告讀一次，若每次都寫，`deliveredAt` 會往後移，經 mesh 收到的回條也會被改成 `firestore`，還多花寫入額度。本機儲存丟出例外時照樣通知（#136），也照樣寫回條，App 重開後可能再寫一次。
- 已讀：`FlutterChatActivity` 把 bridge 的 `onFirstRead` 接到 `recordFirstRead`，只對定向公告呼叫 `read`，時間是儲存記下的 `readAtMs`。
- 寫入：每次都以 merge `set` 寫 `admin_notices/{messageId}/receipts/{當下登入的 uid}`，送達是 `{deliveredAt, via}`，已讀是 `{readAt}`，兩次合成同一份。時間是 Firestore timestamp，精度到毫秒。沒有人登入、或行程裡沒有 Firebase 時什麼都不寫。寫入不等伺服器確認，回傳的 Task 只掛一個 failure listener 留 log；port 丟出的例外由呼叫端攔下（例外傳到 mesh 會被當成不轉送），只留 log，公告的通知、轉送與注入都照常。
- rules 要求每份回條都有 `deliveredAt` 與 `via`，`readAt` 可有可無：只有 `readAt` 的寫入只能補在這個帳號已有的回條上。送達那次沒寫成（例如當時沒有登入）、或同一支手機換帳號之後讀到前一個帳號收到的公告（本機儲存不隨登出清除），寫入會被 rules 拒絕，不會憑空多出一份沒有送達紀錄的回條。
- 回條寫在「寫入當下登入的帳號」底下，不另記收到時是哪個帳號。
- 規則測試見 `firestore-tests/rules.test.mjs` 的 `receipts`；Kotlin 單元測試是 `AdminNoticeReceiptsTest`（Inbox、presenter 與本機儲存，fake 的回條 port）、`AdminNoticeBridgeReadReceiptTest`（`adminNotice_markRead`）、`FirestoreAdminNoticeReceiptsTest`（文件路徑與欄位、不等伺服器確認）。

## 給管理後台的介面契約

這一節給負責管理後台的組別，可以單獨閱讀；格式細節引用前面各節。

**登入**：使用 Administrator 帳號，授予方式同 MESH_GATEWAY.md 第 8 節。

**私鑰**：見「管理端簽章金鑰」，包括私鑰檔的格式。私鑰檔每次發送前載入，後台不得保存；加解密用純 Dart，64 位元欄位不要用 `ByteData.setUint64`。

**發一則公告**：

1. 操作者選擇 kind、level、內容（UI 即時顯示 byte 數，超過 300 bytes 就不能送出）、expiresAt（最長 24 小時），定向公告再選收件對象。messageId 用安全亂數產生。
2. 定向公告要找出每個收件裝置的 `noticePublicKey`：
   - 指定帳號：讀 `reporter_handles/{uid}/installations` 底下的所有文件。
   - 指定 Reporter Handle（例如在 `mesh_reports` 上看到的）：以 collection group 查詢 `installations` 中 `reporterHandle == handle` 的文件，索引見 MESH_GATEWAY.md 第 8 節。有多個 uid 宣稱同一個 Handle 時，只用 `registeredAt` 最新的那份，並提示操作者（可能是冒領，見已知限制）。
   - 每份有 `noticePublicKey` 的文件是一個收件裝置；同一把 `noticePublicKey` 只加密一次（同一台裝置以 uid 和 Handle 都指定到時）。找不到任何收件裝置的對象無法送達，要明確提示操作者；`registeredAt` 超過 30 天的顯示警告，但照樣加密。Python 工具在任何一個對象找不到收件裝置時整批不送，讓操作者先改正收件對象。
   - 收件裝置超過 5 個就拆成多則，每則有自己的 messageId，`admin_notice_records` 用同一個 batchId（第一則的 messageId）串起來。Python 工具把裝置平均分到最少的幾則（6 個拆成 3 + 3，不是 5 + 1）：收件裝置越少 payload 越小，見「大小上限」。整批在同一次 batch write 寫入，不會只送出一半。
3. 依「線路格式」組 payload 並簽章，定向公告依「定向 body」加密。實作要先對過附錄的 test vectors。
4. 用一次 batch write 同時寫入 `admin_notices/{messageId}`（`wire`、`expiresAt`、`createdAt`、`createdBy`，限制見 rules 草稿）與 `admin_notice_records/{messageId}`（欄位見「集合」）。`createdAt` 用 `serverTimestamp()`。

**取代與撤回**：見「撤回與取代」。新公告的 expiresAt 至少等於被取代的那則；撤回一個拆成多則的批次，每一則都要各發一則撤回。不要用刪除 `admin_notices` 文件代替撤回。

- 更正與撤回的 `admin_notice_records` 都填 `replaces`；純撤回的 `kind` 是 `broadcast`、`content` 是空字串，`batchId` 是它自己的 messageId。
- 已經被取代或撤回的公告不要再取代或撤回，撤回本身也不要（App 上「已撤回」是最終狀態，「已更正」只連到一則新公告）。要改已更正的內容，就取代或撤回那則更正。`admin_notice_records` 以 `replaces` 查得到某則是否已被取代。
- 定向更正拆成多則時，每一則的 replaces 都填同一則被取代的公告。
- Python 工具的做法（#139）：純撤回與原公告同時到期，原公告已經或快要過期時至少保留 1 小時；level 沿用原公告。

**回條**：定向公告的收件裝置會寫 `admin_notices/{messageId}/receipts/{uid}`。廣播沒有回條。

- 每個收件帳號一份，文件 ID 是 uid。同一帳號的多台裝置共用這一份，以最後寫入的為準，所以看不出是哪一台；以 Reporter Handle 指定的收件裝置，回條也寫在它當時登入的帳號底下，可以用 `admin_notice_records` 的 `recipientDevices` 對回 uid。

  | 欄位 | 型別 | 說明 |
  |---|---|---|
  | `deliveredAt` | timestamp | 這支手機解開並呈現的時間。一定有 |
  | `via` | string | `firestore`（從 Firestore 收到）或 `ble`（經 mesh 收到，也就是收件者當時沒有網路）。一定有 |
  | `readAt` | timestamp | 使用者第一次在 App 裡讀到的時間。還沒讀過就沒有這個欄位 |

- 時間來自手機時鐘，可能有誤差。經 mesh 收到的回條要等收件者連上網路才寫得進來，可能晚好幾個小時；所以「還沒有回條」不代表沒收到。
- 列出一則公告的回條：讀 `admin_notices/{messageId}/receipts` 這個 collection（只有 Administrator 讀得到）。拆成多則的批次每一則各有自己的回條，以 `batchId` 找出同一批的每一則。
- 刪除 `admin_notices/{messageId}` 不會刪掉底下的回條（Firestore 不連帶刪除子集合），仍讀得到；但之後送來的回條會被 rules 擋下。要收回條就不要提早刪公告文件。

## 收件端呈現

- 收到的公告存在 Kotlin 端的本機儲存，以 messageId 去重，只在第一次寫入時發通知。定向公告解密後的內容要加密儲存（本機儲存從 #136 起就整份加密，#141 以測試確認）。保留到 `expiresAt` 後 7 天，期間標示為「已過期」。
  - 實作是 EncryptedSharedPreferences（與身分金鑰相同的做法），廣播也一起加密，不另分兩種儲存。寫入用 `commit`，通知發出後行程立刻被殺也不會漏記。
  - 寫不進本機儲存時照樣通知：撤離令比重開後重複一次重要，同一個行程內仍有去重表擋著。
  - 純撤回沒有內容，不呈現也不通知；被撤回或更正的公告怎麼標示、內容與通知怎麼處理見「撤回與取代」的實作。
  - 每筆另記 `readAt`（第一次在 App 裡讀到的手機時間）與 `replacedBy`（更正它的那則，#139）。寫入、列出與標記已讀時，順手刪掉已過保留期的那幾筆（#142）。
- 通知由 Kotlin 端發出，每個 level 一個 notification channel：

  | level | channel 重要度 | 行為 |
  |---|---|---|
  | 緊急 | 高 | 聲音與震動；不繞過勿擾模式 |
  | 重要 | 預設 | |
  | 資訊 | 低 | 不出聲 |

  通知不設 category：勿擾模式對鬧鐘、活動或訊息的例外會把它放行。每則通知以 messageId 當 tag，撤回或取代時才找得到它來更新或取消。廣播的通知在鎖定畫面顯示內容，定向公告不顯示。

  實作（#141）：定向公告的通知是 `VISIBILITY_PRIVATE`，附一份只有等級標題與「有一則給你的公告，解鎖後查看」的 public version，安全鎖定畫面顯示的是這一份。使用者在系統設定裡允許鎖定畫面顯示敏感內容時，Android 仍會顯示完整內容，這與其他通訊軟體相同；若要不論設定一律不顯示，得改成 `VISIBILITY_SECRET`，代價是鎖定畫面上完全看不到這則通知。

- `POST_NOTIFICATIONS` 是選用權限。沒有權限時，首頁要放一張醒目的公告卡片代替通知。
  - 「沒有權限」看 `system_status` 的 `notificationGranted`，判斷與 notifier 相同：App 的通知沒被關掉，Android 13 起再加上權限。權限是在系統設定裡改的，原生不推事件，首頁出現與回到前景時重讀。
  - 卡片放最新一則未讀、未過期、沒被更正或撤回的公告，點了開列表（#142）。
- Flutter 端新增「管理端公告」列表畫面，首頁顯示未讀數量，資料經 bridge 從 Kotlin 取得。建議的介面：EventChannel 推送 `type: "admin_notice"`；MethodChannel 照 `chat_`、`settings_` 的慣例命名，提供 `adminNotice_getAll` 與 `adminNotice_markRead(messageId)`，後者同時寫入 `readAt` 回條。收件者金鑰用的 `adminNotice_getPublicKey(uid)`、`adminNotice_clearKey` 見「收件者加密金鑰」。
  - bridge（#142 定案）：`adminNotice_getAll` 回傳保留期內所有公告，新的在前，每則是 `{messageId, kind: broadcast|targeted, level: info|important|urgent, content, issuedAt, expiresAt（毫秒）, status: active|corrected|withdrawn, replacedBy, read}`。「已過期」不在裡面，由 Dart 以 `expiresAt` 與自己的時鐘判斷，畫面開著時也會變。`admin_notice` 事件是 `{type, notices}`，`notices` 與 `getAll` 的回傳相同；儲存有變（新公告、第一次讀到、更正與撤回）就推，只在 Flutter engine 接著時。已更正、已撤回的公告 `content` 是空字串（#139 從儲存清掉）。`adminNotice_markRead({messageId})` 對已讀或已刪除的公告也正常回 null。儲存讀不到時回 `NOTICE_STORE_UNAVAILABLE`，messageId 缺少或為空時回 `INVALID_ARGUMENT`。
  - readAt 回條的接點：Kotlin `flutter/AdminNoticeBridge` 建構子的 `onFirstRead`，只在一則公告第一次被讀到時呼叫一次，帶著已寫入 `readAtMs` 的那筆；廣播也會呼叫，由回條那一側只對定向公告寫回條（#143）。
  - 什麼算「讀了」：列表沒有詳情頁，攤開就是全文，所以列表畫面在前景、在最上面時，列出的未讀公告都標成已讀（畫面開著時新到的也是）；這次開著期間它們仍標「未讀」。未讀數包含已過期、已更正、已撤回的未讀公告。已更正、已撤回的不顯示原內容；已更正的若新公告也在列表上，可以捲過去。

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
8. **回條是自我申報的，也可能少一份。** rules 不知道寫入者是不是真的收件者。送達時沒有登入，或交給 SDK 後行程立刻被終止（待驗證 4），那份回條不會補寫；之後的已讀也會被 rules 擋下。
9. **沒有前景服務就沒有 listener。** 使用者關閉「背景執行」（預設開啟）時，這支手機收不到 Firestore 上的公告，只能等別人經 BLE 傳來，也不會當 Gateway 注入。MESH_GATEWAY.md 第 9 節有同一條限制。
10. **以 Reporter Handle 指定時可能被冒領。** 攻擊者把聽到的 Handle 登記在自己的 uid 底下、`registeredAt` 又比較新時，以那個 Handle 指定的定向公告會加密給攻擊者。日後可以比對 `signingPublicKey` 與 `mesh_reports` 原始封包的簽章 key 來排除（MESH_GATEWAY.md 第 9 節）。

## 實作前待驗證

1. **超過 512 bytes 的 0x31 能不能完整走過 gossip sync。** 已確認可以（#138）：`AdminNoticeFragmentedSyncTest` 的「V5 sent as a sync reply is fragmented, reassembled by the late arrival and accepted by its Inbox」以附錄的 V5（外層封包 683 bytes）走過整條路。sync 回應經 transport 共用的 `FragmentingPacketSender` 切成 2 片（TTL 0）；收到的一方由 `PacketProcessor` 重組，重組後的 0x31 不經 `handleMessage`，而是交給 0x31 的 handler，Inbox 驗過管理端簽章，再加入它自己的 sync 集合。
2. **舊版 App 會不會轉送 0x31。** 已從 main 的程式碼確認會：未知類型的廣播封包 `validPacket` 維持 true，交給 `PacketRelayManager` 轉送；`updatePeerLastSeen` 只更新已存在的 peer。實機驗收時順便觀察即可。
3. **Doze 模式與小米、OPPO 等廠商的省電機制下，前景服務與 listener 能不能保持連線。** 併入實機驗收，與 MESH_GATEWAY.md 第 10 節用同一組手機。
4. **App 被系統終止後重開，離線佇列裡的回條什麼時候送出。** 佇列本身會寫磁碟（ADR-0009）；要確認的是沒有 Flutter 畫面時，Kotlin 端有沒有啟動 Firestore 實例把它送出。已從程式碼與 SDK（firebase-firestore 26.1.2）確認（#143）：前景服務在跑、同一個帳號登入著，就會在有網路時送出，不需要 Flutter 畫面，不必另外補程式。
   - `FirebaseFirestore.getInstance()` 只建立實例，第一次 `collection()` 或 `document()` 才啟動 client（`FirestoreClientProvider.ensureConfigured`）。client 啟動時 `RemoteStore.enableNetwork` 呼叫 `fillWritePipeline`，把磁碟佇列裡的寫入送出；之後 `ConnectivityMonitor` 看到網路變成可達時重新連線再送。原生的預設 FirebaseApp 由 `google-services.json` 在行程啟動時初始化，不靠 Flutter。
   - 行程重開的每一種方式（`START_STICKY` 重啟服務、開機時的 `BootCompletedReceiver`、`BitchatApplication.onCreate` 啟動服務）都會走到 `MeshForegroundService.onCreate`。其中的 `AdminNoticeListenerRuntime` 在 FirebaseAuth 回報已登入時掛上 `admin_notices` 的 listener（`FirestoreAdminNoticeFeed.listen` 呼叫 `collection()`），client 就此啟動。
   - 佇列依 uid 分開（`SQLiteMutationQueue` 以 uid 查 `mutations`），只在那個帳號登入時送出：登出後留著，同一個帳號再登入才送；換成另一個帳號時不會送出前一個帳號的回條。未登入時 listener 不會掛上，這時本來就沒有可送的。
   - 沒有前景服務時（使用者關閉「背景執行」，已知限制 9），行程只會因為使用者打開 App 而啟動。Flutter 的 `main.dart` 在已登入時會寫一次 `reporter_handles` 登記（MESH_GATEWAY.md 7.7），用的是同一個原生實例，同樣會啟動 client。
   - 回條交給 SDK 之後，要等它的 AsyncQueue 寫進磁碟才算進了佇列；行程在這一小段時間內被終止，那份回條就遺失，之後不會補寫（只在第一次存進本機時寫）。
   - 仍要實機確認：A 斷網經 mesh 收到定向公告、殺掉 App、重開後連上網路，回條出現（併入實機驗收第 2 項）。
5. **iOS bitchat 會不會轉送 0x31。** 不在 v1 範圍內，只記錄結果。

## 測試與驗收

**Kotlin 單元測試**

- 附錄的 test vectors：驗過 V1–V3、V5，拒絕 V4；以 recipient-1、recipient-2 解開 V2，以 recipient-1 到 recipient-5 解開 V5，outsider 比對不到任何 tag。
- 「收到 0x31」的每一步各自擋得住；先驗簽才寫去重表與撤回紀錄；去重表的三種情況。
- 撤回與取代：先收到原公告再收到取代，以及反過來，兩種順序都對。
- sync 集合：上限、到期、被取代就移除；超過 512 bytes 的公告經 sync 切片後完整送達（待驗證 1）。
- Gateway 注入：等待期間從 BLE 聽到同一則就不注入；來自快取的文件照樣注入；服務停止時取消待注入；兩支 Gateway 注入同一則，封包 ID 相同。
- 0x31 不建立 peer、不留下 actor、不進實驗 log。
- 收件者金鑰：uid 改變時重新產生；清除後解不開。
- 回條（fake 的回條 port）：Firestore 來源解開時 `via` 是 firestore，mesh 來源是 ble；廣播、不是收件者都不寫；同一則第二份副本、App 重開後再收到都不再寫；回條寫不出去不影響通知與轉送；第一次讀到定向公告才寫 `readAt`。Firestore 實作不等伺服器確認。

**Dart 測試（管理後台）**

- 以相同輸入產生逐位元組相同的 V1–V3、V5，在 Web 上執行。

**規則測試**（`firestore-tests/rules.test.mjs`）

- `admin_notices`：只有 Administrator 能建立與刪除；欄位、`createdBy`、`createdAt`、`expiresAt` 上限、messageId 格式；不能 update。
- `receipts`：只有本人能寫自己的，公告文件要存在；`via` 只能是兩個值之一；欄位只有三個，`deliveredAt` 與 `via` 必填，只有 `readAt` 的寫入被擋；時間是手機時鐘；只有 Administrator 能讀，本人也不行；不能刪除。
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

- 驗過 V1、V2、V3、V5 的簽章，並拒絕 V4。
- 用 recipient-1 與 recipient-2 的私鑰解開 V2；用 outsider 的私鑰比對不到任何 tag。
- 用 recipient-1 到 recipient-5 的私鑰都解得開 V5（條目刻意不照編號排）；outsider 比對不到任何 tag。
- 管理端用相同的輸入，產生逐位元組相同的 V1、V2、V3、V5。

V5 是「大小上限」表的最後一列：5 個收件裝置、內容 300 bytes，外層封包 683 bytes，送上 mesh 會切成 2 片，用來驗證切片後的 sync（實作前待驗證第 1 項）。

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

### V5 組播（緊急，5 個收件裝置，外層封包超過 512 bytes）

```text
messageId: 7a5b3c1d9e8f6a42
issuedAt: 1792627200000
expiresAt: 1792641600000
content (UTF-8): 第三救援隊、第五救援隊及醫療組請注意：大同國小避難所東側通道已因土石崩落封閉，請改由北側中山路進入。現場約有四十名民眾，其中六人需要擔架後送，請攜帶擔架與氧氣瓶，抵達後立即向現場指揮官回報抵達的人數。
content bytes: 300
recipient-3 X25519 private: 78da96d74d479ba3f82e74d10911557b18591b30c4c7cf840ec00907fc6e61e8
recipient-3 X25519 public: a329a3497cdaff7178e3242e11ec65c0c65264993b3d0bb181b695538456c760
recipient-4 X25519 private: c1946f5a8ac3042aedec7f9ce1c2ff032de7d48c4bc6adfe2e97aa49ef43e589
recipient-4 X25519 public: 67463a97e6852a5fe18f45268bb0abf449be13e17eed36684fbfa2ccf8e37e12
recipient-5 X25519 private: 3beeb0d9c85e9720e2d67f625525749c2bfd7fe0bdd38ac44db7022da09ff6bb
recipient-5 X25519 public: 47fb178e09a1c1481b5da4106966c801444320df0d12dccbc15420bc2c43324b
ephemeral X25519 private: 75dc5e6dbfc486931c91111eb8e23c7bbeaa28a944957b0e3aeeef58a3de2540
ephemeral X25519 public: 7ff2642665620d4564fdd4296d74d00b6d4345dbccce0804f17e97afda62b34c
contentKey: 69fada4a6edb29be916232fce2827807b9d7f3bceccd3f31ed421285e0e1bc7b
nonce: 31aebc49d7fa19563d19c990
entry order: recipient-4, recipient-1, recipient-5, recipient-3, recipient-2
recipient-4 tag: d37191cc72eaab65
recipient-1 tag: a325be078784b61a
recipient-5 tag: 024b1a23ea7ee3c9
recipient-3 tag: c7cc646682afe82e
recipient-2 tag: 9bee11ce396fb1f8
payload bytes: 661
outer packet bytes: 683
payload:
  010201037a5b3c1d9e8f6a42000001a160e85000000001a161c40a0000000000
  000000007ff2642665620d4564fdd4296d74d00b6d4345dbccce0804f17e97af
  da62b34c05d37191cc72eaab65dfb1ea60c9df00f27fd9be3fed2f4020b73319
  d86fe072243fa78dc224df5610a325be078784b61a875f8c9eadd66ff7242bc2
  f0d8f72d719c9b432e16acee746355242df5c99ade024b1a23ea7ee3c959ed79
  28d5a71177e828485ed2ffb645c469f863470df1a7e28d1b4d1b259b07c7cc64
  6682afe82ea810feb8d7441eea132d5c91a18f3d2c7f2d656d66f3f4b1f04521
  0a7fdebc099bee11ce396fb1f83f2e40b91fe3d64810f48e25dd53ecb32aa001
  935fb612ae83901c57df3e683c31aebc49d7fa19563d19c990a5ee2f217ec3fa
  bd86123a4e2ab0670e2afc48bed789652f5f766dffcda8969a562fbf772e9911
  39aa48514c42aa89dd2386e95f274d475910d598c78d213c674e9b50c2f5ae34
  da90b8e886dc49b7b5bd1b1b012b665f9cf4eaf3e6406855b065be62bab22a2f
  61292a78cc5b489c3be265d0b8f42e128ec985884202b5330f8fbdfe172ac1e6
  65b962cb3c475d453f1f634a679ec4be933d0c5b48c47aa878ca317cda590976
  9be4071579300e257f398cd3712c6a3c9c9a69290701caaf7d704383f2b2c0e2
  dea612f4cbf416ae9b6fef1ce95815fe96056f75e05e38007c22241bd8c8ea52
  82c37d4c17726c03c5bb8b042600c07aeb13c457148338286f45dc4394981196
  6a288361b0c7a7a233f103b42530816b9ec3ca9bbddc3986039adf1a1acb1f40
  f4f0f2bb51277bafd1c05d900469009d842249b19c512059f4288e4025e37b7d
  fe94ce27999fabcb74e189fda4d2544150001524ed1f3097a37cd57767258701
  3e722fa3b40b06ac612d5b8f0765d42af609796906
```
