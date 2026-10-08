# 00 前置作業、量測工具與共用規範

所有實驗共用的設定、量測工具與記錄格式。每次出發前照第 6 節的清單檢查一遍。

## 1. 裝置登錄

手機的代號 A–J（最多 10 支）全程固定。peerID 只出現在本機原始 log 與這張表中，對外報告一律使用代號。電子檔樣板：[templates/devices.csv](templates/devices.csv)。

這張表把三種識別碼對起來，分析時靠它把原始資料換成代號：

| 識別碼 | 出現在 | 例子 |
|---|---|---|
| 代號 A–J | 手機背面的貼紙、報告、拉 log 時的 `$CODE` | `C` |
| adb serial | `offset_*.csv` 的 `serial` 欄、指令的 `-s` | `9a5e19d9` |
| peerID 前 8 碼 | `exp.csv` 的 `src`、`peer` 欄 | `74483ad0` |

| 代號 | adb serial | 型號 | Android 版本 | 藍牙版本 | 電池健康度 | 電池最佳化設定 | peerID 前 8 碼（僅內部） | E1-A 排名 | 備註 |
|---|---|---|---|---|---|---|---|---|---|
| A | | | | | | | | | |
| B | | | | | | | | | |
| C | | | | | | | | | |
| D | | | | | | | | | |
| E | | | | | | | | | |
| F | | | | | | | | | |
| G | | | | | | | | | |
| H | | | | | | | | | |
| I | | | | | | | | | |
| J | | | | | | | | | |

**各欄怎麼取得**（`S` 是這支手機的 adb serial，指令在 Git Bash 執行）：

| 欄位（devices.csv） | 取得方式 |
|---|---|
| `code` | 自己分配 A–J，貼在手機背面（例如「C／3」，見 [runbook](field-day-runbook.md#裝置代號與實驗-handle)） |
| `adb_serial` | `adb devices` 的第一欄 |
| `model` | `adb -s "$S" shell getprop ro.product.model` |
| `android_version` | `adb -s "$S" shell getprop ro.build.version.release` |
| `bluetooth_version` | adb 查不到，查該型號的規格頁（例如 GSMArena 的 Bluetooth 欄） |
| `battery_health` | 手機的「設定 → 電池」，有健康度百分比就抄；看不到填「未知」 |
| `battery_optimization` | `adb -s "$S" shell dumpsys deviceidle whitelist \| grep bitchat`：有輸出填「不限制」，沒輸出填「最佳化」（預設） |
| `peer_id_prefix_internal_only` | 長按首頁左上角盾牌 → 實驗工具畫面的「本機 peerId」，抄前 8 碼 |
| `e1a_rank` | 做完 E1-A 後，依雙向平均 RSSI 排的名次 |
| `notes` | 手機殼、螢幕裂、容易過熱等 |

- **重新安裝 app 後要更新 peerID**：解除安裝會清掉 mesh 身分，peerID 會換新的。
- repo 裡的樣板保持空白。**填好的版本含 peerID 與 serial，不要 commit**，複製到實驗資料夾（見 [runbook](field-day-runbook.md#session-開始每個場地每個半天各一次)，與 `raw/` 放在一起）。

注意兩組代號不要混用：**裝置代號 A–J** 是手機本身；**位置代號 N1–N7** 是拓撲中的位置（例如線性鏈的第 1～7 個點）。每個 run 都要記下「哪支手機放在哪個位置」。

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
- 不要求充滿電，記下每個 run 開始與結束時的電量即可。
- 任何一支低於 25% 就暫停，換機或充電後再繼續（充電完要拔掉才能開始下一個 run）：電量 ≤ 20% 會切到 POWER_SAVER，留 5% 緩衝。

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

### 3.1 沒有實驗工具時能取得的資料

| 來源 | 內容 | 限制 |
|---|---|---|
| Health 畫面（互助任務列表） | 收到哪些 Reporter 的 Health Report | 每位 Reporter 只保留一筆（任務 id 為 `ble_<handle>`），無法計數 |
| logcat `BitchatBridge` | `📨 收到封包，類型: 0x30, 大小: N` | 沒有 sender、封包時間戳、TTL，無法對到發送端 |
| logcat `PacketRelayManager` | `Evaluating relay ... (TTL: n)`、`🔄 Relaying packet ...` | 可以數轉發次數，但一樣無法對齊 |
| logcat `BluetoothPacketBroadcaster` | `BLE send queue full ...` | E3 可以直接使用 |
| 聊天室的「附近的人」 | 目前看得到的 mesh peer | 只看得到「有沒有」，看不到跳數 |
| nRF Connect（第三方 app） | 對方廣播封包的 RSSI | 與實驗 log 的 `RSSI` 事件量的是同一種東西（廣播 RSSI），可用來交叉檢查 |

結論：只靠這些，只能觀察「有收到／沒收到」，**送達率、延遲、跳數三個核心指標都算不出來**，所以才有 3.2 的實驗工具。

### 3.2 實驗工具

實作於 [#70](https://github.com/dioispen/cares-mesh-app-android/issues/70)。只在 debug build 啟用。不改封包格式，不影響與 iOS 的相容性。操作方式與讀資料時要注意的細節見 [field-day-runbook.md](field-day-runbook.md)。

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
| `peer` | `RX`／`DUP`：上一跳的 peerID 前 8 碼；`QFULL`：那條鏈路的 peerID 前 8 碼；`LINK_*`／`STAT`／`RSSI`：鄰居的 peerID 前 8 碼 |
| `fanout` | `TX`／`RELAY`：實際寫出的鏈路數；0 代表沒有鏈路可送，或藍牙傳輸沒在跑而直接丟棄 |
| `rssi` | `RSSI`：這次掃描收到對方廣播的強度（dBm）；`LINK_UP`／`STAT`：該鄰居最近 60 s 內最新的一筆，沒有就留空。程式不讀連線中的 RSSI（連線的值只在連上時抄一次，不會更新），所以一律用廣播 RSSI |
| `mode` | 當下 app 自己的電源模式（見 2.1） |
| `n_links` | 當下的直連數 |
| `batt` / `temp` | `STAT` 時的電量（%）與電池溫度（°C） |
| `sys_saver` | 當下 Android 系統省電模式是否開著（`1`／`0`）。`mode` 是 app 自己的電源模式，不受它影響 |

| `ev` | 意義 | 記錄的地方 |
|---|---|---|
| `TX` | 本機發出的廣播（**所有類型**，ANNOUNCE 等也算；只看 Health Report 要篩 `type == 0x30`） | `BluetoothPacketBroadcaster` 實際寫出時（只有這裡知道寫出幾條鏈路） |
| `RX` | 第一次收到某封包（已去重、已驗簽），每個封包只有一列 | `SecurityManager.validatePacket` 通過之後 |
| `DUP` | 之後收到的副本（只比對封包 ID，不驗簽；直連鄰居重送的 ANNOUNCE 也記在這裡） | `validatePacket` 的重複判斷分支 |
| `RELAY` | 轉發別人的封包 | `BluetoothPacketBroadcaster` 實際寫出時 |
| `QFULL` | 單一鏈路的送出佇列已滿 | `BluetoothPacketBroadcaster.enqueueSend` |
| `LINK_UP` / `LINK_DOWN` | 與直連鄰居建立或中斷連線 | 連線追蹤（`BluetoothConnectionTracker`） |
| `STAT` | 每 60 s 一筆狀態快照 | 計時器 |
| `RSSI` | 掃描到鄰居的廣播（每個鄰居每秒最多一筆；連上線之後對方仍持續廣播） | `BluetoothGattClientManager` 的掃描結果 |

**(b) 實驗用自動發送器**

Debug 限定的畫面，可設定的參數：

| 參數 | 說明 |
|---|---|
| 筆數 N | 要送幾筆 |
| 間隔（ms） | 兩筆之間的間隔，允許 0（突發測試用） |
| TTL | 0～7（滑桿）。TTL n 最遠到第 n + 1 跳：0 只到直連鄰居；3 = 現行 Health Report；7 = `MESSAGE_TTL_HOPS` |
| 開始時間 | 牆鐘 `HH:mm:ss`，讓多支手機在同一時刻開始 |
| Status | 預設「安全」 |
| 保持喚醒 | 預設開：run 期間持有 wake lock，螢幕關閉也照排程送。**E4 要關掉**，否則手機無法休眠，背景存活與耗電會偏樂觀。關掉時 CPU 休眠會讓排程延後，醒來後不補送錯過的筆數 |

- Payload 使用與 `sendHealthReport` 相同的 Health Report Broadcast Tier 編碼。每支手機用固定的實驗 handle（`ee0000000001`～`ee0000000010` 對應 A～J），走的路徑與真實 Health Report 相同。
- 每一筆交給 mesh 的都會有一個 `TX` 事件；mesh 服務沒在跑而沒收下的筆數沒有 `TX`，畫面上記為「mesh 未收下」。
- 發送迴圈跑在 `MeshForegroundService` 的 scope 裡，app 進背景、離開實驗畫面都會繼續送。
- 只走 mesh，不寫入 Firestore。

**為什麼要能設 TTL**：現行 Health Report 送出時固定 TTL 3（[BitchatFlutterChannels.kt](../../app/src/main/java/com/bitchat/android/flutter/BitchatFlutterChannels.kt) 的 `sendHealthReportPacket`），依程式碼推算最遠只到第 4 跳。要量 7 支手機線性鏈（6 跳）的物理極限，必須用 TTL 7。

**(c) 現場即時計數**

實驗畫面顯示最近 20 s／60 s 內依實驗 handle 收到的筆數、目前的直連數、電源模式與系統省電模式，以及發送器的「寫出結果」。只算實驗 handle，一般 Health 畫面送出的 Health Report 不會出現在這裡。這是現場用的回饋：放置中繼（E2-C）、判斷要不要重做某個 run，都靠這個畫面，不必等回去拉 log 才發現資料是壞的。

### 3.3 跳數與延遲的推算

- **跳數** `h = TTL_送出 − TTL_收到 + 1`。發送端送出時不扣 TTL，之後每轉發一次扣 1。
- **延遲** `L = (t_RX − off_收) − (pts − off_送)`。其中 `off_X = 手機 X 的時鐘 − 筆電時鐘`，由 3.4 節量測。

### 3.4 時鐘偏移量測

每個 session 開始前與結束後各量一次（同一台筆電）。一次只接一支手機也可以：所有手機都寫進同一個檔案，接一支、量一支、拔掉、換下一支。

指令在實驗資料夾裡執行（見 [runbook](field-day-runbook.md#session-開始每個場地每個半天各一次) 的「Session 開始」），`SESSION` 已經設好。macOS 內建的 date 不支援 `%N`，要改用 coreutils 的 gdate。

**1. 設定輸出檔（session 前、後各設一次；換手機時不要重跑）**

```bash
# session 開始前量的寫進 offset_pre.csv；session 結束後量的，把 pre 改成 post
out="raw/$SESSION/offset_pre.csv"
mkdir -p "raw/$SESSION"
# 檔案不存在才寫標題列；之後重跑這段也不會清掉已經量好的資料
[ -f "$out" ] || echo "serial,t0_ms,phone_ms,t1_ms" > "$out"
```

**2. 每接上一支手機就跑一次（換下一支時按 ↑ 重跑這段）**

```bash
# 確認只列出這一支，而且狀態是 device
adb devices
# 處理已授權的手機：略過 `adb devices` 的標題列，以及狀態不是 device（unauthorized、offline）的手機
for s in $(adb devices | awk 'NR>1 && $2=="device" {print $1}'); do
  # 每支量 10 次
  for i in $(seq 1 10); do
    t0=$(date +%s%3N)                               # 筆電時間（ms），問手機之前
    d=$(adb -s "$s" shell date +%s%N | tr -d '\r')  # 手機時間（ns）；去掉 adb shell 輸出結尾的 \r
    t1=$(date +%s%3N)                               # 筆電時間（ms），手機回答之後
    echo "$s,$t0,${d:0:13},$t1" >> "$out"           # ns 的前 13 位就是 ms；>> 是附加，不會覆蓋前一支
  done
done
# 確認這一支的 serial 有寫進去
tail -n 3 "$out"
```

- 用同一個 Git Bash 視窗量完所有手機，`$out` 才會一直在。視窗關掉重開的話，重設 `SESSION` 再跑步驟 1（不會清掉已經量好的資料）。
- 某一支量錯想重量，直接再跑一次步驟 2。分析時每支只取該 serial 的最後 10 筆。
- `offset = phone_ms − (t0 + t1) / 2`。**Windows 的 Git Bash 每次啟動 `date`、`adb` 都很慢，`t1 − t0` 實測約 120～250 ms**，無法要求 100 ms 以下。所以：
  - 捨棄 `t1 − t0 > 300 ms` 的樣本。
  - 剩下的樣本中，取 `t1 − t0` 最小的 5 筆，offset 取這 5 筆的中位數。
  - 偏移的不確定度約為這 5 筆 `t1 − t0` 中位數的一半（約 ±60～120 ms），一併記下。延遲類指標的誤差不會小於這個值。
- Day 0 先確認 `adb shell date +%s%N` 輸出的是純數字。較舊的 toybox 不支援 `%N`，會直接輸出字母 N，這時要另找方法。
- **量完要拔線**。接著 USB 會被視為充電，手機會切到 PERFORMANCE 模式。
- 前後兩次的偏移差即為時鐘漂移。差距在上面的不確定度以內就當作沒有漂移，取兩次的平均；超過的話，以線性內插校正。

### 3.5 Log 收集

Session 開始前：

```bash
# S：這支手機的 adb serial（`adb devices` 的第一欄），例如 S=R58N12ABCDE

# 刪掉上一次的實驗 log。exp.csv 在 app 的私有目錄，要透過 run-as 以 app 的身分操作（debug build 才可以）
adb -s "$S" shell run-as com.bitchat.droid rm -f files/exp.csv
# 把手機的 logcat 緩衝區加大到 16 MB，長時間的 session 前面的 log 才不會被覆蓋
adb -s "$S" logcat -G 16M
# 清空 logcat，之後拉出來的只有這個 session 的 log
adb -s "$S" logcat -c
```

Session 結束後（在實驗資料夾裡執行，`SESSION` 是 session 開始時設的那個）：

```bash
# S 同上，是這支手機的 adb serial
# CODE：這支手機的代號 A～J，從 devices.csv 用 serial 查出來（第 1 欄 code、第 2 欄 adb_serial）
CODE=$(awk -F, -v s="$S" '$2==s {print $1}' devices.csv)
# 查不到就停下來：先把這支的 serial 補進 devices.csv，否則檔名會變成 raw/$SESSION/.exp.csv
[ -n "$CODE" ] && echo "代號 $CODE" || echo "devices.csv 裡沒有 $S"

# 每個 session 一個資料夾
mkdir -p "raw/$SESSION"
# 從 app 的私有目錄讀出實驗 log，存成「代號.exp.csv」
adb -s "$S" shell run-as com.bitchat.droid cat files/exp.csv > "raw/$SESSION/$CODE.exp.csv"
# 匯出整份 logcat：-d 印完就結束，-v epoch 以 Unix 時間（秒，含小數到 ms）標示每一行，方便和 exp.csv 對時
adb -s "$S" logcat -d -v epoch > "raw/$SESSION/$CODE.logcat.txt"
```

- 檢查 `exp.csv` 第一筆的時間是否早於 session 開始時間，最後一筆是否晚於 session 結束時間。不符合就代表資料不完整，該 run 要重做。
- `raw/` 含 peerID，**不進 repo**，放在 repo 外的實驗資料夾。整理後只保留以 A–J 表示的彙總結果。

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

### 3.7 點位記錄與量距

`exp.csv` 只有時間，沒有位置或距離。**距離類的結果（`d_rel`、`d_max`、RSSI–距離曲線、牆後距離、可發現距離）全靠現場記下「哪段時間站在幾公尺」**，事後用時間把 log 切成一段一段。沒有這份記錄，log 只能看出「某個時刻斷線了」，換算不出公尺。

距離類的實驗（E1-A、E1-B、E2 的距離掃描、E4-B2、E5 的走近）每站定一個點位，在 [templates/stations.csv](templates/stations.csv) 記一列：

| 欄位 | 說明 |
|---|---|
| `run_id` | 對應 runs.csv 的 `run_id` |
| `station` | 點位編號或名稱，例如 `P0`、`30m`、`牆後5m` |
| `distance_m` | 與參考機（或發送端）的地面距離 |
| `distance_method` | `tape`（捲尺）、`wheel`（測距輪）、`laser`（雷射測距儀）、`track`（跑道標線）、`map`（地圖量測） |
| `distance_err_m` | 估計誤差，例如捲尺填 0.1、地圖填 3 |
| `phones` | 這個點位上的手機與角色，例如 `P=C Q=D` |
| `t_start` / `t_end` | 站好開始量、量完要移動的牆鐘時間（到秒，`HH:mm:ss`） |
| `notes` | 遮蔽、有人經過、地面材質改變等 |

**記錄員的時鐘**：用手機的時鐘，在開飛航模式之前讓它自動對時。秒級的準度就夠用，切段時前後各留幾秒緩衝。

**量距工具**

| 工具 | 誤差約 | 適合 |
|---|---|---|
| 50 m 捲尺 | < 0.1 m | 5～50 m，E1-B 前段的每個點位 |
| 測距輪 | 約 0.5%（100 m 差 0.5 m） | 50 m 以上，一個人就能推 |
| 雷射測距儀（高爾夫、打獵用） | ±1 m，可量數百 m | 長距離；對方要舉著能反射的目標 |
| 操場跑道標線 | 幾乎沒有誤差 | 直道的 10 m 記號、100 m 起點與終點 |
| Google 地圖「測量距離」 | 約 ±2～5 m，看衛星圖解析度與點選位置 | 只用在 ≥ 100 m，而且兩端都是衛星圖上看得到的地標（路燈、球門、路口） |
| 手機 GPS 定位 | ±3～10 m，靠近建築物更差 | **不要用**：30 m 以內誤差可能比距離本身還大 |

**點位要事先做好記號**：開始前用捲尺或測距輪把 5、10、20、30……m 的位置量好，用粉筆、三角錐或地貼做記號，實驗時直接走到記號站好。用地圖補的遠距離點位，`distance_method` 填 `map` 並寫上誤差。

### 3.8 要手工記的項目

下面這些 log 裡沒有，只能現場記。其餘的 RSSI、PDR、延遲、跳數、`LINK_UP`／`LINK_DOWN`、電源模式、系統省電，都從 `exp.csv` 算。

| 項目 | 記在哪裡 | 為什麼要手工記 |
|---|---|---|
| 每個點位的起訖時間與距離 | stations.csv | 3.7：沒有它算不出任何距離類結果 |
| 哪支手機在哪個位置 | runs.csv `topology`、stations.csv `phones` | log 只看得到 peerID，看不出位置 |
| 打開藍牙（或進入範圍）的時刻 | 各實驗的記錄表（T_disc） | log 只有 `LINK_UP`，沒有起點 |
| 手機高度、拿法、朝向 | runs.csv `anomalies`（與 2.2 不同時才記） | 高度與人體遮擋對 RSSI 影響很大 |
| 場地狀況：遮蔽、地面材質、附近的金屬圍籬或電塔 | runs.csv `location`／`anomalies` | 用來解釋異常值 |
| 天氣、氣溫、附近 Wi-Fi AP 數 | runs.csv | 2.2 的環境條件 |
| 每支手機的電量（開始、結束） | runs.csv `battery_start`／`battery_end` | 判斷有沒有掉進 POWER_SAVER；`STAT` 的 `batt` 只是輔助 |
| 異常事件與發生的牆鐘時間 | runs.csv `anomalies` | 判斷哪一段要排除或重做 |
| 現場畫面的收到筆數 | 各實驗的記錄表 | 當場決定要不要重做，不必等回去拉 log |
| 牆厚（cm）、材質、樓層、門開或關（E2） | E2 的記錄表 | 計算障礙衰減時要用 |

## 4. 共用指標定義

| 指標 | 符號 | 定義 | 計算方式 |
|---|---|---|---|
| 送達率 | PDR | 接收端收到的唯一封包數 ÷ 發送數 | 以 `(src, pts)` 對齊 `TX` 與 `RX` |
| 端到端延遲 | L | 收到時間 − 封包時間戳（已校正時鐘偏移） | 報 p50、p95、最大值 |
| 跳數 | h | 封包從來源到接收端經過的鏈路數 | `TTL_送出 − TTL_收到 + 1` |
| 每跳延遲 | ΔL | 延遲對跳數的斜率 | 對 (h, L) 做線性迴歸 |
| RSSI | — | 收到對方廣播的訊號強度（dBm）。「P 收 Q」＝P 的 `exp.csv` 裡 `peer` 為 Q 的 `RSSI` 列 | 該條件下 30 s 內 `RSSI` 列的中位數（約 20 個樣本）。廣播發射功率隨電源模式變，跨模式比較要註明 |
| 衰減 | ΔRSSI | 同距離下，對照組 RSSI − 實驗組 RSSI（dB） | — |
| 發現時間 | T_disc | 兩機進入範圍（或打開藍牙）到 `LINK_UP` 的時間 | 開始時刻以碼錶記牆鐘，結束時刻取自 log |
| 重複率 | R_dup | (RX + DUP) ÷ RX | 每個節點平均每個唯一封包收到幾份 |
| 傳輸成本 | C_tx | 全網的 (TX + RELAY) ÷ 唯一封包數 | 只算同一種 `type`（例如 0x30）。flooding 的代價；乘上 `fanout` 即為鏈路層傳輸次數 |
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
- [ ] devices.csv 已填好（含 adb serial 與重裝後的 peerID），放在實驗資料夾
- [ ] 每支的電量已記下（低於 25% 的已充電），充電線與行動電源已拔除
- [ ] 飛航模式開、藍牙開、定位開、Wi-Fi 關
- [ ] 螢幕逾時設為最長，亮度調到最低
- [ ] 時鐘偏移已量測（session 前）
- [ ] `exp.csv` 已清空，logcat buffer 已設定並清空
- [ ] 帶齊捲尺／測距輪、碼錶、記錄表（含 stations.csv 的紙本）、筆電、USB 線、手機架、點位記號用的粉筆或三角錐
- [ ] 距離類實驗的點位已量好並做記號（3.7）
- [ ] 每個人都知道自己的位置代號與要負責的步驟
