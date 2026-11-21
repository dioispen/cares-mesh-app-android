# Admin Notice 發送工具與操作手冊

給 Administrator 操作者看的手冊：管理端私鑰怎麼保管與分發，以及怎麼用 `admin_notice_tool.py` 發一則 Admin Notice。格式與規則以 [docs/ADMIN_NOTICE_V1.md](../../docs/ADMIN_NOTICE_V1.md) 為準；名詞見 [CONTEXT.md](../../CONTEXT.md)。

這支工具是**開發用**的，也是**管理後台組不接發送頁面時的備案**。後台組接下的話，日常發送改用管理後台，這支工具留給開發與測試。

支援**廣播**、**定向公告**（以 uid 或 Reporter Handle 指定收件對象），以及已發出公告的**更正**與**撤回**（#139）。

## 發公告之前

- **實地實驗進行中不發公告。** 公告會在 mesh 上洪泛、經 gossip sync 一路補送到到期為止，會干擾實驗的量測（docs/ADMIN_NOTICE_V1.md「處理規則」）。發之前先向實驗負責人確認現在沒有實驗在跑。
- **送出後收不回來。** 公告一進到 mesh 就會被一路轉送，刪除 Firestore 文件**不是**撤回。寫錯了只能發更正或撤回（見「更正與撤回」），而沒收到撤回的手機會一直看到原公告到它過期，所以有效期不要設得比需要的長。
- 定向公告的內容只有收件裝置解得開，但 `admin_notice_records` 留有明文與收件對象，只有 Administrator 讀得到。
- **內容最多 300 bytes**（UTF-8，大約 100 個中文字）；**有效期最長 24 小時**。超過的話工具會拒絕，不會送出。
- 寫進 `admin_notices` 的只有簽好章的 `wire`。所有登入帳號都讀得到它，任何 Gateway 都會把它注入 mesh，所以廣播的內容要當成公開的；定向公告的 `wire` 只看得出有幾個收件裝置。

## 管理端私鑰

### 是什麼

- 一把 Ed25519 私鑰，keyId `0x01`，所有操作者共用一把（v1 的設計，見 ADR-0011）。App 內建對應的公鑰，只相信這把 key 簽出的公告。
- 公鑰登記在 [`admin_public_keys.json`](admin_public_keys.json)（keyId → 32 bytes 公鑰的十六進位），App 依它內建公鑰表。
- 私鑰檔是一行 64 個小寫十六進位字元，也就是 Ed25519 的 32 bytes seed（RFC 8032 的 private key）。管理後台以純 Dart 載入時，例如用 `package:cryptography` 的 `newKeyPairFromSeed`。
- 正式私鑰已在 2026-11-15 產生（`keygen`），**不要再產生一次**：沒有人能替別的私鑰簽出 App 認得的公告，App 只認公鑰表裡的那一把。

### 存放

- 預設路徑 `~/.config/cares-mesh/admin-notice/admin-ed25519-01.key`。目錄權限 0700、檔案權限 0600，只有自己讀得到。
- **不進版控**：`.gitignore` 已經擋下 `admin-ed25519-*.key`，但不要把私鑰複製進 repo。
- **不進任何雲端**：不放 Google Drive、Dropbox、iCloud 這類同步資料夾，不經 email、LINE、Slack、Discord 或任何通訊軟體傳送，不寫進 Firestore。管理後台**不得**保存它（localStorage、IndexedDB、Firestore 都不行）：每次發送前選檔載入，只放在分頁的記憶體裡。
- 在 Windows 上 0600 權限不會生效：把檔案放在只有自己能登入的帳號底下，並開啟磁碟加密（例如 BitLocker）。
- 不要對私鑰檔執行 `cat`、`hexdump`、`base64` 這類會把內容印出來的指令，也不要截圖或貼進 issue、PR 或聊天室。

### 分發與備份（手動作業）

- **誰可以持有**：由專案負責人決定，只給需要發公告的 Administrator 操作者，人數越少越好。持有人名單由專案負責人記錄。
- **怎麼交給新的操作者**：面對面交付，不經網路傳送。用加密的 USB 隨身碟（例如 VeraCrypt 或 LUKS 加密磁碟區）把檔案複製到對方的電腦，放到預設路徑後設好權限：

  ```bash
  install -d -m 700 ~/.config/cares-mesh/admin-notice
  install -m 600 /media/usb/admin-ed25519-01.key ~/.config/cares-mesh/admin-notice/
  ```

  只是拿來搬運的那份複本，複製完就從隨身碟刪掉。
- **備份**：至少一份離線備份，放在加密的 USB 隨身碟，由專案負責人保管。私鑰遺失又沒有備份時，只能換 key（見下），而換 key 要發新版 App。
- **操作者退出專案**：刪掉對方的 `admins/{uid}` 文件，對方就不能再寫進 Firestore。但私鑰是共用的，無法單獨撤銷某個人；對方仍可能直接把公告注入 mesh。依風險決定要不要換 key。
- **私鑰外洩**：立刻通知專案負責人。在使用者更新 App 之前，偽造的公告都會被接受（docs/ADMIN_NOTICE_V1.md「已知限制」1）。處理方式是發一版移除該 key 的 App，並換一把新 key。

### 換 key

1. 以新的 keyId 產生金鑰：`python3 tools/admin-notice/admin_notice_tool.py keygen --key-id 0x02`。指令只印出公鑰，私鑰寫在 `~/.config/cares-mesh/admin-notice/admin-ed25519-02.key`；檔案已經存在時會拒絕，不會覆寫。
2. 把公鑰加進 `admin_public_keys.json`，舊的 keyId 先保留。
3. 發一版同時內建新舊兩把公鑰的 App；多數使用者更新後，改用 `send --key-id 0x02` 發公告。
4. 再發一版移除舊 key 的 App，並把它從 `admin_public_keys.json` 移除。

外洩時跳過第 3 步的等待，直接發移除舊 key 的版本。

## 發一則廣播

### 需要

- Python 3.9 以上與 `cryptography`（`pip install cryptography`），其他只用標準函式庫。在 repo 的 checkout 裡執行：工具從 `app/google-services.json` 讀 Firebase 專案與 Web API key。
- Administrator 帳號：由專案管理者在 Firebase console 建立 `admins/{你的 uid}` 文件（docs/MESH_GATEWAY.md 第 8 節）。不是 Administrator 的帳號會被 security rules 擋下，什麼都不會寫入。
- 私鑰檔放在預設路徑，或用 `--key` 指定。

### 步驟

1. 先用 `--dry-run` 看一次：只組包與簽章，印出摘要與 `wire`，不登入也不寫入。

   ```bash
   python3 tools/admin-notice/admin_notice_tool.py send --dry-run \
     --email you@example.org --level urgent --valid-for 6h \
     --content "土石流警戒：請立即撤離至大同國小避難所"
   ```

2. 確認內容、等級與到期時間，拿掉 `--dry-run` 再執行一次。工具會提醒實驗期間不發公告，輸入 `yes` 才送出。
3. 輸入 Administrator 帳號的密碼。密碼**不能**放在命令列參數，免得留在 shell history。要用環境變數 `CARES_ADMIN_PASSWORD` 的話，用 `read -rs CARES_ADMIN_PASSWORD && export CARES_ADMIN_PASSWORD` 輸入，不要寫成 `export CARES_ADMIN_PASSWORD=...`。
4. 看到「已寫入 admin_notices/… 與 admin_notice_records/…」就完成了。Gateway 讀到後會在 0–15 秒內把它注入 mesh（App 端的實作見 #134 之後的票）。

### 參數

| 參數 | 說明 |
|---|---|
| `--email` | Administrator 帳號的 email（必填） |
| `--level` | `info`（資訊，不出聲）、`important`（重要）、`urgent`（緊急，響鈴並震動）（必填） |
| `--content` | 公告內容，UTF-8 最多 300 bytes（必填） |
| `--valid-for` | 有效期，例如 `6h`、`90m`、`1h30m`，最長 `24h`（必填） |
| `--key-id` | 私鑰的 keyId，預設 `0x01` |
| `--key` | 私鑰檔路徑，預設 `~/.config/cares-mesh/admin-notice/admin-ed25519-<keyId>.key` |
| `--project` | Firestore 專案，預設是 `app/google-services.json` 的 `bitchat-android-disaster-app` |
| `--yes` | 不詢問，直接送出 |
| `--uid` | 定向公告的收件帳號，可以重複，見「發一則定向公告」 |
| `--handle` | 定向公告的收件 Reporter Handle，可以重複，見「發一則定向公告」 |
| `--dry-run` | 只組包、簽章並印出，不寫入。廣播不登入；定向公告要登入查收件裝置 |

### 工具做了什麼

1. 檢查內容與有效期；用安全亂數產生 messageId（不會全為 0）；依 docs/ADMIN_NOTICE_V1.md「線路格式」組 payload 並簽章。組包與簽章的程式碼和附錄 test vectors 的產生器共用（`notice_format.py`）。
2. 用 `admin_public_keys.json` 裡同一個 keyId 的公鑰驗一次。私鑰檔選錯時拒絕送出：那樣的公告會被每一支 App 丟掉。
3. 以 email 與密碼經 Firebase Auth REST API（`accounts:signInWithPassword`）登入。不用 service account，security rules 才會套用。
4. 用一次 Firestore REST `documents:commit` 同時建立兩份文件，兩份都要求「文件還不存在」：
   - `admin_notices/{messageId}`：`wire`、`expiresAt`（與 wire 裡簽過的相同）、`createdAt`（伺服器時間）、`createdBy`（你的 uid）。
   - `admin_notice_records/{messageId}`：明文留存，欄位見 docs/ADMIN_NOTICE_V1.md「Firestore」。

### 錯誤

| 訊息 | 原因與處理 |
|---|---|
| 登入失敗 | email 或密碼錯誤 |
| 寫入失敗：`PERMISSION_DENIED` | 帳號不是 Administrator（`admins/{uid}` 不存在），或文件格式不符 rules。什麼都沒有寫入 |
| 寫入失敗：`ALREADY_EXISTS` | messageId 撞號（機率極低），什麼都沒有寫入；重新執行即可 |
| 私鑰檔與 admin_public_keys.json 登記的公鑰不符 | 選錯私鑰檔，或 `--key-id` 不對 |

## 發一則定向公告

定向公告只有收件裝置解得開：轉送它的人看不到內容，也看不出是發給誰的。需要的東西與廣播相同，再加上收件對象。

### 收件對象

- `--uid <uid>`：一個帳號。加密給它在 `reporter_handles/{uid}/installations` 底下登記過的**每一台**裝置。
- `--handle <Reporter Handle>`：一台裝置，例如在 `mesh_reports` 上看到的 Handle（12 個十六進位字元）。只經由 mesh 求救、從沒自己上傳過的 Reporter，用這個指定。
- 兩者都可以重複、可以混用；同一台裝置被指定兩次只算一次。
- 每份有 `noticePublicKey` 的登記是一台收件裝置。舊版 App 寫的登記沒有它，收不到定向公告。

### 步驟

1. 先用 `--dry-run` 看一次。定向公告要讀收件裝置的公鑰，只有 Administrator 讀得到，所以 `--dry-run` 也會登入；它只查詢，不寫入。

   ```bash
   python3 tools/admin-notice/admin_notice_tool.py send --dry-run \
     --email you@example.org --level important --valid-for 2h \
     --uid <uid> --handle <reporter handle> \
     --content "救援人員約 10 分鐘內抵達，請留在原地"
   ```

2. 看清楚印出的收件裝置與警告，拿掉 `--dry-run` 再執行一次。工具列出收件裝置之後才問要不要送出，輸入 `yes` 才寫入。
3. 看到每一則的「已寫入 admin_notices/… 與 admin_notice_records/…」就完成了。

### 警告與錯誤

| 訊息 | 原因與處理 |
|---|---|
| 找不到收件裝置，什麼都沒有送出 | 列出的收件對象沒有任何可加密的裝置：帳號從未在有網路時登入過新版 App、Handle 沒有人登記，或最新的登記是舊版 App。任何一個對象找不到就整批不送；改正或拿掉它再送 |
| 警告：Reporter Handle … 有 N 個帳號宣稱 | 同一個 Handle 登記在幾個 uid 底下。只加密給 `registeredAt` 最新的那份。可能是同一支手機換過帳號，也可能是有人把聽到的 Handle 登記在自己底下（冒領，docs/ADMIN_NOTICE_V1.md 已知限制 10）。不確定時改用 `--uid` |
| 警告：收件裝置 … 的登記超過 30 天 | 那支手機可能已經換帳號、重裝或不再使用。照樣加密給它，只是它可能收不到 |
| 查詢收件裝置失敗：`PERMISSION_DENIED` | 帳號不是 Administrator |
| 查詢收件裝置失敗：`FAILED_PRECONDITION` | 正式環境還沒建立 `installations.reporterHandle` 的 collection group 索引（docs/MESH_GATEWAY.md 第 8 節）。emulator 不需要索引 |

### 超過 5 台收件裝置

每則定向公告最多 5 台收件裝置。超過時工具自動拆成最少的幾則，每則的裝置數盡量平均（6 台拆成 3 + 3，不是 5 + 1：收件裝置越少 payload 越小，4 台以內、內容 169 bytes 以內的公告不必切片）。每則有自己的 messageId，`admin_notice_records` 以同一個 `batchId`（第一則的 messageId）串起來，整批在同一次 commit 寫入，不會只送出一半。

撤回一個拆成多則的批次時，每一則都要各發一則撤回：用 `revoke --batch <batchId>`（見「更正與撤回」）。

### 工具做了什麼

1. 和廣播一樣先檢查內容、有效期與私鑰，任何一項不對就在登入前拒絕。
2. 登入後以 Firestore REST `runQuery` 查收件裝置：`--uid` 查 `reporter_handles/{uid}/installations`；`--handle` 以 collection group 查詢（`allDescendants`）找 `reporterHandle == handle` 的登記。查詢都經過 security rules。
3. 每則用新的一次性 X25519 金鑰、contentKey 與 nonce 加密，收件條目以隨機順序排列（`notice_format.build_targeted`，docs/ADMIN_NOTICE_V1.md「定向 body」），再簽章並用 `admin_public_keys.json` 驗一次。
4. 一次 `documents:commit` 建立每一則的 `admin_notices/{messageId}`（只有 `wire`，沒有收件者）與 `admin_notice_records/{messageId}`。

### `admin_notice_records` 的收件欄位

廣播的欄位之外，定向公告的紀錄多了這幾個（docs/ADMIN_NOTICE_V1.md「Firestore」）：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `recipientUids` | array of string | 操作者以 `--uid` 指定的帳號，依指定的順序；同一批的每一則都一樣 |
| `recipientHandles` | array of string | 操作者以 `--handle` 指定的 Reporter Handle；同一批的每一則都一樣 |
| `recipientCount` | integer | 這一則加密給的收件裝置數，即 `wire` 的 recipientCount |
| `recipientDevices` | array of map | 這一則加密給的每台收件裝置：`uid`、`reporterHandle`（登記文件的路徑）與 `noticePublicKey`（當時用的公鑰）。順序與 `wire` 裡的條目無關 |

## 更正與撤回

公告送出後就收不回來，只能再發一則**取代**它的公告（docs/ADMIN_NOTICE_V1.md「撤回與取代」）。收到的手機會把原公告標成「已更正」或「已撤回」、清掉它的內容、收回它的通知，中繼也不再補送它。**不要**用刪除 `admin_notices` 文件代替撤回：公告已經在 mesh 上，刪除文件攔不住它。

### 更正：`send --replaces`

在 `send` 加上 `--replaces <messageId>`（被更正那則的 `admin_notices` 文件 ID），其他參數照發新公告：

```bash
python3 tools/admin-notice/admin_notice_tool.py send --dry-run \
  --email you@example.org --level urgent --valid-for 6h \
  --replaces a1b2c3d4e5f60718 \
  --content "土石流警戒：請改至中山國中避難所"
```

- 原公告在手機上標成「已更正」，列表可以捲到新公告；新公告照一般公告通知，依它的等級再響一次。
- **新公告的到期時間不能早於原公告**，否則工具拒絕，並印出最短的 `--valid-for`：撤回紀錄要撐到原公告過期為止。
- **定向公告只能用定向公告更正**，內容才會加密：加上 `--uid` 或 `--handle`，通常與原公告相同。廣播也可以用定向公告更正，但只有收件裝置看得到新內容，工具會提醒。
- 原公告屬於拆成多則的批次時，這次只更正那一則，工具會列出同一批的其他則。要整批收回，用 `revoke --batch` 撤回後重發。
- 更正拆成多則時，每一則都取代同一則原公告。
- 需要讀 `admin_notice_records`，所以 `--dry-run` 也會登入（廣播的一般發送不會）。

### 撤回：`revoke`

```bash
# 撤回一則
python3 tools/admin-notice/admin_notice_tool.py revoke --dry-run --email you@example.org a1b2c3d4e5f60718
# 撤回一整批（拆成多則的定向公告），每一則各發一則撤回
python3 tools/admin-notice/admin_notice_tool.py revoke --dry-run --email you@example.org --batch a1b2c3d4e5f60718
```

- 純撤回一律是**廣播 kind、空 body**，不論原公告是廣播還是定向：沒有內容就不必加密，也不需要收件者的公鑰。等級沿用原公告。
- 撤回與原公告**同時到期**；原公告已經或快要過期時，撤回至少保留 1 小時，讓列表裡還留著它的手機（保留到過期後 7 天）也收得到。原公告的到期時間超過現在起 24 小時（發它的電腦時鐘快了）時拒絕。
- `--batch` 以 `batchId` 查出同一批的每一則，整批在同一次 commit 寫入；已經被更正或撤回的那幾則略過並提醒。
- 參數：`--email`（必填）、`<messageId>` 或 `--batch <batchId>`（擇一）、`--key-id`、`--key`、`--project`、`--yes`、`--dry-run`，意思同 `send`。`--dry-run` 會登入查要撤回的公告，簽好章印出，不寫入。

### 什麼時候拒絕

| 訊息 | 原因與處理 |
|---|---|
| 找不到 `admin_notice_records/…` | messageId 打錯了，或不是發到這個專案的公告 |
| … 已經被 … 更正 | 一則公告只取代一次：要再改，就取代或撤回那則更正 |
| … 已經撤回過了 | 不必再撤回 |
| … 本身是一則撤回 | 撤回不能再取代或撤回，被撤回的公告也不會因此回來 |
| … 是定向公告：更正它的新公告也必須是定向的 | 加上 `--uid` 或 `--handle`，或改用 `revoke` |
| 新公告 … 到期，早於被取代的 … | 加長 `--valid-for`，訊息裡有最短的值 |
| batchId … 的公告都已經被取代或撤回 | 整批都處理過了 |

### `admin_notice_records`

更正與撤回的紀錄都填 `replaces`（被取代的 messageId）。純撤回的 `kind` 是 `broadcast`、`content` 是空字串、`batchId` 是它自己的 messageId；工具以 `replaces` 查一則公告是否已被取代過。

## 測試

- 單元測試，不連任何網路：在本目錄執行 `python3 -m unittest`。Firebase 在 HTTP 邊界換成假的；emulator 整合測試會被略過。
- 對著 Firebase emulator 跑整合測試（需要 Java），確認 REST 查詢與 commit 真的通得過 `firestore.rules`：

  ```bash
  cd firestore-tests && npm ci && npm run test:admin-notice-tool
  ```

- 自己對著 emulator 發：同時設定 `FIRESTORE_EMULATOR_HOST` 與 `FIREBASE_AUTH_EMULATOR_HOST`（只設一個會被拒絕），並加上 `--project` 指定 emulator 的專案，例如 `--project demo-cares`。
- `test_gen_test_vectors.py` 確認 `gen_test_vectors.py` 的輸出仍與規格書附錄一致。改動 `notice_format.py` 後一定要跑。

## 檔案

| 檔案 | 用途 |
|---|---|
| `admin_notice_tool.py` | 命令列：`keygen`、`send`（廣播、定向公告與更正）、`revoke`（撤回一則或一整批） |
| `notice_format.py` | payload 的組包、簽章、定向加密與檢查，與產生器共用 |
| `firebase_rest.py` | Firebase Auth 與 Firestore 的 REST 呼叫（登入、commit、batchGet、runQuery），只用標準函式庫 |
| `gen_test_vectors.py` | 產生規格書附錄的 test vectors |
| `admin_public_keys.json` | keyId → 正式公鑰，App 內建公鑰表的來源 |
| `test_*.py` | 單元測試與 emulator 整合測試 |
