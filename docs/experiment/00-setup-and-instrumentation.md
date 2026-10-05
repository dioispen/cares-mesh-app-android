# 00 前置作業、量測工具與共用規範

所有實驗共用的設定、量測工具與記錄格式。每次出發前照第 6 節的清單檢查一遍。

## 1. 裝置登錄

7 支手機的代號 A–G 全程固定。peerID 只出現在本機原始 log 與這張表中，對外報告一律使用代號。電子檔樣板：[templates/devices.csv](templates/devices.csv)。

| 代號 | 型號 | Android 版本 | 藍牙版本 | 電池健康度 | 電池最佳化設定 | peerID 前 8 碼（僅內部） | E1-A 排名 | 備註 |
|---|---|---|---|---|---|---|---|---|
| A | | | | | | | | |
| B | | | | | | | | |
| C | | | | | | | | |
| D | | | | | | | | |
| E | | | | | | | | |
| F | | | | | | | | |
| G | | | | | | | | |

注意兩組代號不要混用：**裝置代號 A–G** 是手機本身；**位置代號 N1–N7** 是拓撲中的位置（例如線性鏈的第 1～7 個點）。每個 run 都要記下「哪支手機放在哪個位置」。

## 2. 控制變因

### 2.1 電源模式（最大的干擾因子）

`PowerProfileResolver`（[PowerManager.kt](../../app/src/main/java/com/bitchat/android/mesh/PowerManager.kt)）會依前景／背景、是否充電、電量自動切換電源模式。模式改變的不只是掃描週期，**廣播發射功率也會跟著變**，所以會直接影響距離類的數據：

| 狀態 | 模式 | BLE 掃描 | 廣播模式 / 發射功率 | Announce 間隔 |
|---|---|---|---|---|
| 前景、未充電、電量 > 20% | BALANCED | 掃 8 s／停 2 s | BALANCED / MEDIUM | 30 s |
| 前景、充電中（含接 USB、行動電源） | PERFORMANCE | 連續掃描 | LOW_LATENCY / HIGH | 30 s |
| 前景、電量 11–20% | POWER_SAVER | 掃 2 s／停 28 s | LOW_POWER / LOW | 60 s |
| 前景、電量 ≤ 10% | ULTRA_LOW_POWER | 掃 1 s／停 29 s | LOW_POWER / ULTRA_LOW | 120 s |
| 背景、電量 > 20% | POWER_SAVER | 掃 1 s／停 29 s（有直連鄰居）<br>掃 1 s／停 59 s（無直連鄰居） | LOW_POWER / LOW | 60 s |
| 背景、電量 11–20% | POWER_SAVER | 同上 | LOW_POWER / LOW | 120 s |
| 背景、電量 ≤ 10% | ULTRA_LOW_POWER | 同上 | LOW_POWER / ULTRA_LOW | 300 s |

**除了 E4 以外，所有實驗都固定在 BALANCED 模式**：

- App 保持在前景，螢幕不關：螢幕逾時設成最長，亮度調到最低並固定。
- **不接充電線、不接行動電源**。一接上就會切到 PERFORMANCE，發射功率變成 HIGH，量到的距離會被高估。
- 開始時電量 ≥ 50%，任何一支低於 25% 就暫停，換機或充電後再繼續（充電完要拔掉才能開始下一個 run）。
- 每個 run 的開始與結束都記一次電量。

### 2.2 其他固定條件

| 項目 | 設定 | 原因 |
|---|---|---|
| App 版本 | 同一個 commit 的 debug build，**全新安裝** | 最大連線數（預設 8）與 relay 開關存在 SharedPreferences，殘留的舊值會改變行為；Flutter UI 也進不去 debug 面板，現場無法檢查 |
| 無線電 | 先開飛航模式，再手動打開藍牙與定位；Wi-Fi 保持關閉 | 減少 2.4 GHz 的自身干擾，同時確保只走 BLE（Wi-Fi Aware 預設也是關閉） |
| 手機高度 | 1.2 m（胸前手持，或放在固定高度的架子上） | 高度對距離影響很大；放在地面另外列為 E2-D 的變項 |
| 手機方向 | 直立，螢幕朝向下一個節點 | 手機天線有方向性 |
| 持機人位置 | 站在手機後方，不要擋在兩支手機之間 | 人體是 2.4 GHz 的強吸收體 |
| 穩定時間 | 所有 app 開啟後至少等 120 s 才開始發送 | Announce 間隔 30 s，留 4 輪讓 peer 清單收斂 |
| 環境 | 記錄天氣、氣溫、附近 Wi-Fi AP 數量（關 Wi-Fi 之前，用 Wi-Fi 掃描 app 看一次） | 2.4 GHz 的擁擠程度會影響結果 |

## 3. 量測工具

### 3.1 現況能取得的資料

| 來源 | 內容 | 限制 |
|---|---|---|
| Health 畫面（互助任務列表） | 收到哪些 Reporter 的 Health Report | 每位 Reporter 只保留一筆（任務 id 為 `ble_<handle>`），無法計數 |
| logcat `BitchatBridge` | `📨 收到封包，類型: 0x30, 大小: N` | 沒有 sender、封包時間戳、TTL，無法對到發送端 |
| logcat `PacketRelayManager` | `Evaluating relay ... (TTL: n)`、`🔄 Relaying packet ...` | 可以數轉發次數，但一樣無法對齊 |
| logcat `BluetoothPacketBroadcaster` | `BLE send queue full ...` | E3 可以直接使用 |
| Setup 畫面的附近節點 | `getNearbyPeers` 回傳的 peer 清單 | 只看得到「有沒有」，看不到跳數 |
| nRF Connect（第三方 app） | 對方廣播封包的 RSSI | 量到的是廣播 RSSI，不是連線中的 RSSI |

結論：只靠現有工具，只能觀察「有收到／沒收到」。**送達率、延遲、跳數三個核心指標都算不出來。**

### 3.2 需要補上的實驗工具

已實作於 [#70](https://github.com/dioispen/cares-mesh-app-android/issues/70)。只在 debug build 啟用。不改封包格式，不影響與 iOS 的相容性。實作與下列規格的差異（`TX` 涵蓋本機所有廣播、`LINK_UP` 的時機、`STAT` 每條直連一列等）與操作方式見 [field-day-runbook.md](field-day-runbook.md)。

**(a) 結構化實驗 log**

每個事件寫一行到 logcat，tag 為 `CARES_EXP`，並同時 append 到 app 私有目錄的 `exp.csv`。logcat 是 ring buffer，長時間實驗的資料會被沖掉，所以分析一律以 `exp.csv` 為準。

| 欄位 | 說明 |
|---|---|
| `t_ms` | 事件發生時本機的 `System.currentTimeMillis()` |
| `ev` | 事件種類，見下表 |
| `type` | MessageType（hex） |
| `src` | 封包 senderID 前 8 碼 |
| `pts` | 封包標頭的 timestamp（發送端時鐘，ms）。**`(src, pts)` 可以唯一識別一個封包** |
| `ttl` | 收到或送出時的 TTL |
| `len` | 封包長度（bytes） |
| `peer` | `RX`／`DUP`：上一跳的 peerID 前 8 碼；`LINK_*`：鄰居的 peerID 前 8 碼 |
| `fanout` | `TX`／`RELAY`：實際寫出的鏈路數 |
| `rssi` | `LINK_UP` 與 `STAT` 時的連線 RSSI（可取得時才填） |
| `mode` | 當下的電源模式 |
| `n_links` | 當下的直連數 |
| `batt` / `temp` | `STAT` 時的電量（%）與電池溫度（°C） |

| `ev` | 意義 | 建議插入點 |
|---|---|---|
| `TX` | 本機發出原始封包 | 實驗發送器 |
| `RX` | 第一次收到某封包（已去重） | `SecurityManager.validatePacket` 通過之後 |
| `DUP` | 收到重複封包而丟棄 | `validatePacket` 的重複判斷分支 |
| `RELAY` | 轉發 | `PacketRelayManager.relayPacket` |
| `QFULL` | 單一鏈路的送出佇列已滿 | `BluetoothPacketBroadcaster.enqueueSend` |
| `LINK_UP` / `LINK_DOWN` | 與直連鄰居建立或中斷連線 | 連線追蹤（`BluetoothConnectionTracker`） |
| `STAT` | 每 60 s 一筆狀態快照 | 計時器 |

**(b) 實驗用自動發送器**

Debug 限定的畫面，可設定的參數：

| 參數 | 說明 |
|---|---|
| 筆數 N | 要送幾筆 |
| 間隔（ms） | 兩筆之間的間隔，允許 0（突發測試用） |
| TTL | 3 = 現行 Health Report；7 = `MESSAGE_TTL_HOPS` |
| 開始時間 | 牆鐘 `HH:mm:ss`，讓多支手機在同一時刻開始 |
| Status | 預設「安全」 |

- Payload 使用與 `sendHealthReport` 相同的 Health Report Broadcast Tier 編碼。每支手機用固定的實驗 handle（`ee0000000001`～`ee0000000007` 對應 A～G），走的路徑與真實 Health Report 相同。
- 每一筆都寫一個 `TX` 事件。
- 發送迴圈要跑在 `MeshForegroundService` 的 scope 裡，螢幕關閉後也要繼續送（E4 需要）。
- 只走 mesh，不寫入 Firestore。

**為什麼要能設 TTL**：現行 Health Report 送出時固定 TTL 3（[BitchatFlutterChannels.kt](../../app/src/main/java/com/bitchat/android/flutter/BitchatFlutterChannels.kt) 的 `sendHealthReportPacket`），依程式碼推算最遠只到第 4 跳。要量 7 支手機線性鏈（6 跳）的物理極限，必須用 TTL 7。

**(c) 現場即時計數**

在發送器畫面上顯示「最近 N 秒內收到的實驗封包數（依來源）」與目前的直連數。這是現場用的回饋：放置中繼（E2-C）、判斷要不要重做某個 run，都靠這個畫面，不必等回去拉 log 才發現資料是壞的。

### 3.3 跳數與延遲的推算

- **跳數** `h = TTL_送出 − TTL_收到 + 1`。發送端送出時不扣 TTL，之後每轉發一次扣 1。
- **延遲** `L = (t_RX − off_收) − (pts − off_送)`。其中 `off_X = 手機 X 的時鐘 − 筆電時鐘`，由 3.4 節量測。

### 3.4 時鐘偏移量測

每個 session 開始前與結束後各量一次（同一台筆電，手機逐一接 USB）：

```bash
# offset.sh — 量測每支手機相對於筆電的時鐘偏移
out="offset_$(date +%Y%m%d_%H%M).csv"
echo "serial,t0_ms,phone_ms,t1_ms" > "$out"
for s in $(adb devices | awk 'NR>1 && $2=="device" {print $1}'); do
  for i in $(seq 1 10); do
    t0=$(date +%s%3N)
    d=$(adb -s "$s" shell date +%s%N | tr -d '\r')
    t1=$(date +%s%3N)
    echo "$s,$t0,${d:0:13},$t1" >> "$out"
  done
done
```

- `offset = phone_ms − (t0 + t1) / 2`，取 10 次的中位數。`t1 − t0 > 100 ms` 的樣本捨棄。
- Day 0 先確認 `adb shell date +%s%N` 輸出的是純數字。較舊的 toybox 不支援 `%N`，會直接輸出字母 N，這時要另找方法。
- **量完要拔線**。接著 USB 會被視為充電，手機會切到 PERFORMANCE 模式。
- 前後兩次的偏移差即為時鐘漂移，一般應該小於 50 ms。超過的話，以線性內插校正。

### 3.5 Log 收集

Session 開始前：

```bash
adb -s "$S" shell run-as com.bitchat.droid rm -f files/exp.csv
adb -s "$S" logcat -G 16M
adb -s "$S" logcat -c
```

Session 結束後：

```bash
mkdir -p "raw/$SESSION"
adb -s "$S" shell run-as com.bitchat.droid cat files/exp.csv > "raw/$SESSION/$CODE.exp.csv"
adb -s "$S" logcat -d -v epoch > "raw/$SESSION/$CODE.logcat.txt"
```

- 檢查 `exp.csv` 第一筆的時間是否早於 session 開始時間，最後一筆是否晚於 session 結束時間。不符合就代表資料不完整，該 run 要重做。
- `raw/` 含 peerID，**不進 repo**。整理後只保留以 A–G 表示的彙總結果。

### 3.6 Run 記錄

每次發送（一個 run）在 [templates/runs.csv](templates/runs.csv) 記一列：

| 欄位 | 說明 |
|---|---|
| `run_id` | `實驗-條件-重複次數`，例如 `E1C-s0.8-r1` |
| `date` / `start` / `end` | 牆鐘時間 |
| `location` | 地點、GPS 或樓層、點位編號 |
| `weather_temp` | 天氣與氣溫 |
| `wifi_ap_count` | 附近 Wi-Fi AP 數 |
| `topology` | 拓撲與間距，例如 `line s=40m N1=C N2=A ...` |
| `sender` / `ttl` / `n` / `interval_ms` | 發送參數 |
| `battery_start` / `battery_end` | 例如 `A85 B90 C77 ...` |
| `power_mode` | 實際的電源模式 |
| `app_commit` | 安裝的 build 的 commit hash |
| `anomalies` | 例如：有人從中間走過、某支手機螢幕關了、app 閃退 |
| `recorder` | 記錄者 |

## 4. 共用指標定義

| 指標 | 符號 | 定義 | 計算方式 |
|---|---|---|---|
| 送達率 | PDR | 接收端收到的唯一封包數 ÷ 發送數 | 以 `(src, pts)` 對齊 `TX` 與 `RX` |
| 端到端延遲 | L | 收到時間 − 封包時間戳（已校正時鐘偏移） | 報 p50、p95、最大值 |
| 跳數 | h | 封包從來源到接收端經過的鏈路數 | `TTL_送出 − TTL_收到 + 1` |
| 每跳延遲 | ΔL | 延遲對跳數的斜率 | 對 (h, L) 做線性迴歸 |
| RSSI | — | 連線中的訊號強度（dBm） | 該條件下 30 s 內的中位數 |
| 衰減 | ΔRSSI | 同距離下，對照組 RSSI − 實驗組 RSSI（dB） | — |
| 發現時間 | T_disc | 兩機進入範圍（或打開藍牙）到 `LINK_UP` 的時間 | 開始時刻以碼錶記牆鐘，結束時刻取自 log |
| 重複率 | R_dup | (RX + DUP) ÷ RX | 每個節點平均每個唯一封包收到幾份 |
| 傳輸成本 | C_tx | 全網的 (TX + RELAY) ÷ 唯一封包數 | flooding 的代價；乘上 `fanout` 即為鏈路層傳輸次數 |
| 重複交付 | — | 同一個 `(src, pts)` 在同一節點出現兩次以上 `RX` | 應為 0 |

## 5. 統計慣例

- 送達率：每個條件至少 50 筆，並附上 Wilson 95% 信賴區間。50/50 全部收到時，只能宣稱 PDR ≥ 92.9%；想宣稱 ≥ 99%，需要約 380 筆全部收到。
- 延遲：報中位數與 p95，不報平均值（BLE 延遲有長尾）。
- 發現時間：每個條件至少重複 5 次。
- 每個條件至少做 2 次 run。兩次的 PDR 相差超過 10 個百分點時，補做第三次。

## 6. 安全與隱私

- 戶外場地避開車道。器材需要有人看守，夏天注意防曬與補水。
- 建築物實驗要事先取得管理單位同意。不進入電梯井、機房，也不靠近屋頂邊緣。
- 實驗封包一律使用實驗 handle，Status 設為「安全」，**不要用真實帳號送出**。
- 對外報告不放 peerID、藍牙位址、帳號、私人住宅的精確座標。這與 [device-transport-test-matrix.md](../device-transport-test-matrix.md) 的規範一致。

## 7. 出發前檢查清單

- [ ] 7 支手機都安裝了同一個 commit 的 debug build，已記錄 commit hash
- [ ] 電量 ≥ 80%，充電線與行動電源已拔除
- [ ] 飛航模式開、藍牙開、定位開、Wi-Fi 關
- [ ] 螢幕逾時設為最長，亮度調到最低
- [ ] 時鐘偏移已量測（session 前）
- [ ] `exp.csv` 已清空，logcat buffer 已設定並清空
- [ ] 帶齊捲尺／測距輪、碼錶、記錄表、筆電、USB 線、手機架
- [ ] 每個人都知道自己的位置代號與要負責的步驟
