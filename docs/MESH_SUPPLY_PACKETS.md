# Mesh 物資封包（SUPPLY_EXCHANGE，0x32）

物資頁的「申請物資」與「捐贈物資」送出時，除了寫進雲端自己的 `supply_requests`／`supply_pledges`，
同時經 BLE mesh 廣播一份不含 PII 的 `SUPPLY_EXCHANGE` 封包。附近的手機收到後顯示在物資頁的
「附近與我的」分頁（不需要網路）；已登入、有網路、開著「代傳附近的求救與回報」開關的手機
（Gateway，ADR-0009）把它寫進 Firestore 的 `mesh_supply_packets`，給管理後台調度物資。

領域語彙見 [CONTEXT.md](../CONTEXT.md)。Gateway 的整體設計見 [MESH_GATEWAY.md](MESH_GATEWAY.md)。

## 線路格式

`MessageType.SUPPLY_EXCHANGE = 0x32`，沒有 content tag（與 `HEALTH_REPORT` 不同）。`0x31` 已保留給 Admin Notice（[ADR-0011](adr/0011-admin-notice-trusts-admin-signature-only.md)），不能用。payload：

| 位移 | 欄位 | 大小 | 說明 |
|---|---|---|---|
| 0 | version | 1 | 目前為 `1`；其他版本拒收 |
| 1 | action | 1 | `1` = request（要求物資）、`2` = offer（捐贈物資） |
| 2 | exchangeId | 16 | 隨機 UUID，與本人寫進 Firestore 的文件 ID 相同（去掉連字號） |
| 18 | itemIdLen + itemId | 2 + ≤64 | UTF-8 型錄 ID（`supply_items` 的文件 ID） |
| … | itemNameLen + itemName | 2 + ≤96 | UTF-8 品名快照（接收端離線時沒有型錄可查） |
| … | quantity | 4 | unsigned big-endian，≥ 1 |
| … | unitLen + unit | 1 + ≤16 | UTF-8 單位 |

最大 203 bytes，常見約 45 bytes（仍在 100 bytes 的壓縮門檻之下）。封包標頭的 timestamp 是建立時間。
TTL 與 Health Report 相同（`HealthReportBroadcast.DEFAULT_TTL`，目前為 7，見 [ADR-0014](adr/0014-broadcast-reports-use-upstream-ttl.md)）：物資需求不該比求救傳得更遠。

**權威向量**：`app/src/test/kotlin/.../protocol/SupplyExchangePacketTest.kt` 與
`flutter_ui/test/supply_exchange_packet_test.dart` 使用同一組 bytes，改格式時兩邊一起改。

## 送出（Flutter `supply_screen.dart`）

1. 產生 `SupplyRequest`／`SupplyPledge`（UUID v4 文件 ID）。
2. `BitchatBridge.sendSupplyExchange(exchangeId = UUID 去連字號, …)` → Kotlin `SupplyExchangeBroadcast`
   簽章、廣播、登記進 gossip sync。
3. 以 batch 寫 `supply_requests`／`supply_pledges` 與 `supply_items` 的計數。**最多等 8 秒**：離線時
   Firestore 的寫入永遠不會完成（資料已進本機佇列，連線後自動送出），畫面不能卡住。
4. snackbar 說明兩條路各自的結果（`SupplyDelivery`）。

兩條路各自獨立：mesh 失敗不影響雲端，雲端離線不影響 mesh。

## 接收（Kotlin → Flutter）

`MessageHandler.handleSupplyExchange`：只收已驗證 peer 的封包（簽章由 `SecurityManager` 驗過）、
解碼成功後交給 `InboundPacketBridge`（Flutter）與 `VerifiedSupplyExchangeBridge`（Gateway）。
Flutter 端 `SupplyExchangeFeed` 從 app 啟動就監聽，同一個發送者的同一個 exchangeId 只留一筆
（別的 peer 重送同一個 exchangeId 蓋不掉它），保留 2 小時、標頭時間比現在晚超過 10 分鐘的不收，
最多 200 筆，物資頁「附近與我的」分頁顯示。

**已知限制**：ADR-0006 的驗簽 key 快取只給 `HEALTH_REPORT`。物資封包納入 gossip sync，但發送者離開
超過 3 分鐘後補送的物資封包會因沒有 signing key 被丟棄。要補送就要把物資封包納入 ADR-0006 的機制。

## Gateway（Kotlin `gateway/MeshSupplyGateway`）

與 Health Report 的 `MeshGateway` 同一個 `MeshGatewayRuntime`，共用登入、網路與開關事件。
上傳條件：開關開啟、已登入、封包年齡 ≤ 2 小時且標頭時間不比現在晚 10 分鐘以上（與規則相同；
遠在未來的封包若暫存會卡住補傳）、這個 Packet ID 還沒傳過。沒網路或暫時性錯誤時
暫存在記憶體（不寫磁碟，最多 1000 筆），網路恢復、登入或下一筆上傳成功時補傳。

去重以 Packet ID（`PacketIdUtil`：type、senderID、timestamp、payload 的 SHA-256 前 16 bytes）為單位，
文件只能 create 不能 update，第二支 Gateway 寫同一份得到 `PERMISSION_DENIED`，視同已上傳。

## Firestore：`mesh_supply_packets/{packetId}`

| 欄位 | 型別 | 說明 |
|---|---|---|
| `schemaVersion` | int | 固定 `1` |
| `packetId` | string | 32 碼小寫十六進位，等於文件 ID |
| `exchangeId` | string | 32 碼小寫十六進位；等於 `supply_requests`／`supply_pledges` 的文件 ID（去連字號） |
| `action` | string | `request` 或 `offer` |
| `originPeerId` | string | 封包標頭 senderID，16 碼小寫十六進位 |
| `itemId`、`itemName`、`quantity`、`unit` | string／int | 封包內容 |
| `createdAt` | timestamp | 封包標頭時間（發送者手機的時鐘） |
| `uploadedAt` | timestamp | 伺服器時間 |
| `gatewayUid` | string | 寫入者 uid（稽核用） |
| `rawPacket` | bytes | 收到的封包原樣編碼（不含 BLE padding），含簽章，日後驗簽用 |

規則（`firestore.rules`）：只有 Administrator（`admins/{uid}`）能讀、能刪；任何登入帳號可 create，
`gatewayUid` 必須是自己；`createdAt` 容忍未來 10 分鐘、過去 2 小時 10 分鐘；不可 update。

### 給管理後台

- 「這一區缺什麼」：讀 `mesh_supply_packets`，`action == 'request'`，依 `itemId` 加總 `quantity`。
- **去重**：同一個人有網路時也會寫 `supply_requests/{uuid}`。把 `exchangeId` 與 `supply_requests` 的
  文件 ID（去連字號、小寫）對照，對得上的只算一筆。對不上的代表發送者全程沒有網路。
- 封包沒有姓名或 uid；`gatewayUid` 是代傳者，不是需求者。
- 取消／滿足的狀態只在 `supply_requests.status`，mesh 封包是事件、不會更新。

### 部署

規則變更走 PR（見 README）。部署前跑 `cd firestore-tests && npm test`。
**線上規則沒有 `mesh_supply_packets` 之前，Gateway 的上傳一律 `PERMISSION_DENIED`**（App 會視同
已上傳、不會重試），`mesh_supply_packets` collection 不會出現。
