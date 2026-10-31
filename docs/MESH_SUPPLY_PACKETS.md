# Mesh 物資封包與 Firebase 設定

## 傳送行為

物資需求與捐贈共用新的 `SUPPLY_EXCHANGE` 封包種類（`0x31`），與 Health Report 的 `0x30` 分開。payload 有自己的版本位元組，並以 `action` byte 區分 `request` 與 `offer`。封包沿用既有 BLE mesh 簽章、relay 與 gossip sync；初始 TTL 為 **7 hops**。TTL 是最多可轉送的 hop 計數，不代表每條路徑都保證送達七跳。

接收端只處理格式正確且通過既有封包簽章驗證的訊息。有效封包先寫入 App 私有目錄的持久化 outbox，再嘗試上傳；因此離線時會跨服務／程序重啟保留。網路恢復或 Firebase 使用者登入後會重試。已成功建立或已存在同一 Packet ID 文件後，該筆才會從 outbox 移除。

outbox 最多保存 1,000 筆，未上傳前不因時間自動過期。若已達上限，新封包會保留在 mesh relay 流程，但不加入此裝置的上傳佇列，並寫入錯誤 log。Firebase 上傳需要 Firebase Authentication 使用者登入；未登入時封包仍可留在本機等待登入。

## Firestore collection

使用 Firebase 專案 **`bitchat-android-disaster-app`**。collection 名稱為 **`mesh_supply_packets`**；不需在 Console 預先建立 collection，第一筆成功寫入時 Firestore 會建立它。

文件路徑：

```text
mesh_supply_packets/{packetId}
```

文件 ID 為 Packet ID：`PacketIdUtil` 對封包 type、原始 sender ID、timestamp 和 payload 計算 SHA-256，取前 16 bytes，編為 32 位小寫十六進位字串。relay 修改 TTL 不會改變 ID。

| 欄位 | Firestore 型別 | 說明 |
|---|---|---|
| `schemaVersion` | number | 文件結構版本，目前為 `1` |
| `packetId` | string | 32 位小寫十六進位 Packet ID，必須等於文件 ID |
| `packetType` | number | 固定 `49`（十進位 `0x31`） |
| `payloadVersion` | number | 物資 payload 版本，目前為 `1` |
| `action` | string | `request`（要求物資）或 `offer`（捐贈物資） |
| `originPeerId` | string | 原始發送端 16 位小寫十六進位 mesh peer ID |
| `itemId` | string | 物資型錄 ID |
| `itemName` | string | 發送當時的物資名稱快照 |
| `quantity` | number | 正整數數量，wire 格式上限為 uint32 |
| `unit` | string | 數量單位 |
| `createdAt` | timestamp | 來自原始封包標頭的發送時間 |
| `rawPacket` | string | gateway 將收到的封包重新編碼（不含 BLE padding）後，以 Base64 儲存；含封包簽章供稽核 |
| `gatewayUid` | string | 首次成功建立此文件的登入使用者 UID |
| `receivedAt` | timestamp | Firestore server timestamp，首次成功寫入時間 |

封包不廣播姓名、電話、Firebase UID 或其他使用者個資。`gatewayUid` 是上傳者，不是捐贈者／需求者。原始封包簽章由 Android mesh 安全流程驗證；Firestore Security Rules 會檢查欄位與格式，但不能自行驗證 Ed25519 簽章或重算 Packet ID。

## 重複封包

Android Gateway 以 Firestore transaction 讀取文件 ID：

- 文件不存在：建立文件。
- 文件已存在：不修改既有文件，視為已處理。

因此相同 Packet ID 即使由不同登入者／Gateway 收到，也只保留第一份文件，首次的 `gatewayUid` 與 `receivedAt` 不會被後續重送覆寫。不同封包 ID 的需求或捐贈會保留為不同文件。

本 collection 與 `supply_requests`、`supply_pledges` 是不同資料用途：後兩者是使用者在 App 直接建立的個人紀錄；`mesh_supply_packets` 是 mesh 收到的簽章訊息及 Gateway 稽核資料。

## Firebase Console／部署設定

1. 確認 Firebase Console 專案 ID 為 `bitchat-android-disaster-app`。
2. 在 **Authentication → Sign-in method** 啟用 App 使用的 Email/Password 登入方式。Gateway 需有目前登入的 Firebase 使用者，Firestore Rules 才接受上傳。
3. 確認此專案已啟用 Cloud Firestore。
4. 部署 repository 的 `firestore.rules` 至該專案：

   ```sh
   firebase deploy --only firestore:rules --project bitchat-android-disaster-app
   ```

5. 不必手動建立 `mesh_supply_packets` collection 或預建文件；首次有效封包上傳時自動建立。
6. 如果管理後台需要讀取整個 collection，將管理者 UID 建立為 `admins/{uid}` 文件（例如內容 `{ "grantedAt": <timestamp> }`）。規則允許一般登入者讀取已知 Packet ID，供去重 transaction 使用；只有 `admins/{uid}` 存在的 Administrator 可以列出／查詢整個 collection。

Firestore 的自動 TTL policy **不需要設定**：文件 `createdAt` 是原始封包時間，但封包 TTL `7` 是 BLE hop count，並非文件存活時間。collection 目前沒有自動刪除策略。

Android 專案使用的 Firebase Options 已對齊 `app/google-services.json`。Flutter iOS／Web Options 不在這次 Android mesh 功能範圍內，仍維持原有設定。

## Firestore Rules 測試

本機 emulator 測試不會部署至線上專案：

```sh
cd firestore-tests
npm test
```
