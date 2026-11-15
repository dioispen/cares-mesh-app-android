# Admin Notice 發送工具與操作手冊

給 Administrator 操作者看的手冊：管理端私鑰怎麼保管與分發，以及怎麼用 `admin_notice_tool.py` 發一則 Admin Notice。格式與規則以 [docs/ADMIN_NOTICE_V1.md](../../docs/ADMIN_NOTICE_V1.md) 為準；名詞見 [CONTEXT.md](../../CONTEXT.md)。

這支工具是**開發用**的，也是**管理後台組不接發送頁面時的備案**。後台組接下的話，日常發送改用管理後台，這支工具留給開發與測試。

目前只支援**廣播**。取代、撤回與定向公告由之後的票補上。

## 發公告之前

- **實地實驗進行中不發公告。** 公告會在 mesh 上洪泛、經 gossip sync 一路補送到到期為止，會干擾實驗的量測（docs/ADMIN_NOTICE_V1.md「處理規則」）。發之前先向實驗負責人確認現在沒有實驗在跑。
- **送出後收不回來。** 公告一進到 mesh 就會被一路轉送，刪除 Firestore 文件**不是**撤回。這支工具還不能撤回，寫錯了只能等它過期，所以有效期不要設得比需要的長。
- **內容最多 300 bytes**（UTF-8，大約 100 個中文字）；**有效期最長 24 小時**。超過的話工具會拒絕，不會送出。
- 寫進 `admin_notices` 的只有簽好章的 `wire`。所有登入帳號都讀得到它，任何 Gateway 都會把它注入 mesh，所以內容要當成公開的。

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
| `--dry-run` | 只組包、簽章並印出，不登入也不寫入 |

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

## 測試

- 單元測試，不連任何網路：在本目錄執行 `python3 -m unittest`。Firebase 在 HTTP 邊界換成假的；emulator 整合測試會被略過。
- 對著 Firebase emulator 跑整合測試（需要 Java），確認 REST commit 真的通得過 `firestore.rules`：

  ```bash
  cd firestore-tests && npm ci && npm run test:admin-notice-tool
  ```

- 自己對著 emulator 發：同時設定 `FIRESTORE_EMULATOR_HOST` 與 `FIREBASE_AUTH_EMULATOR_HOST`（只設一個會被拒絕），並加上 `--project` 指定 emulator 的專案，例如 `--project demo-cares`。
- `test_gen_test_vectors.py` 確認 `gen_test_vectors.py` 的輸出仍與規格書附錄一致。改動 `notice_format.py` 後一定要跑。

## 檔案

| 檔案 | 用途 |
|---|---|
| `admin_notice_tool.py` | 命令列：`keygen`、`send` |
| `notice_format.py` | payload 的組包、簽章與檢查，與產生器共用 |
| `firebase_rest.py` | Firebase Auth 與 Firestore 的 REST 呼叫，只用標準函式庫 |
| `gen_test_vectors.py` | 產生規格書附錄的 test vectors |
| `admin_public_keys.json` | keyId → 正式公鑰，App 內建公鑰表的來源 |
| `test_*.py` | 單元測試與 emulator 整合測試 |
