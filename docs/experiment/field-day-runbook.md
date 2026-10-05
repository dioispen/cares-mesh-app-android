# 實驗當天流程

把 [00](00-setup-and-instrumentation.md) 的規範與 #70 實作出來的量測工具串成一天的操作順序。各實驗的佈置、距離、筆數照 E1～E5 各自的文件；這份只管「每個 session、每個 run 要按什麼、看什麼、拉什麼」。

## 角色

| 角色 | 人數 | 負責 |
|---|---|---|
| 總控 | 1 | 筆電、adb、時鐘偏移、拉 log、喊開始時間、決定要不要重做 |
| 記錄員 | 1 | runs.csv、記錄表、異常與發生的牆鐘時間 |
| 持機人 | 每支手機 1 人（可兼任） | 依位置代號站位、操作自己那支手機的實驗畫面 |

## 裝置代號與實驗 handle

最多 10 支手機。裝置代號 A～J 對應實驗畫面的「裝置編號」1～10，發送時的 handle 是 `ee` 加編號補零成 10 位。**每支手機背面貼上代號與編號**（例如「C／3」），發送前一定要選自己的編號，否則接收端會把兩支手機算成同一個來源。

| 代號 | 裝置編號 | handle |
|---|---|---|
| A | 1 | ee0000000001 |
| B | 2 | ee0000000002 |
| C | 3 | ee0000000003 |
| D | 4 | ee0000000004 |
| E | 5 | ee0000000005 |
| F | 6 | ee0000000006 |
| G | 7 | ee0000000007 |
| H | 8 | ee0000000008 |
| I | 9 | ee0000000009 |
| J | 10 | ee0000000010 |

`exp.csv` 的 `src` 是 peerID 前 8 碼，不是 handle。對照靠 [devices.csv](templates/devices.csv) 的 `peer_id_prefix_internal_only`（實驗畫面上的「本機 peerId」）。

## 前一天：安裝與登錄

1. 在 `feat/physical-experiment-plan` 分支建 debug build，記下 commit：
   ```bash
   git rev-parse --short HEAD          # 填進 runs.csv 的 app_commit
   export JAVA_HOME="C:/Program Files/Android/Android Studio/jbr"
   ./gradlew assembleDebug
   ```
2. 每支手機**全新安裝**（00 §2.2）：
   ```bash
   for s in $(adb devices | awk 'NR>1 && $2=="device"{print $1}'); do
     adb -s "$s" uninstall com.bitchat.droid
     adb -s "$s" install app/build/outputs/apk/debug/app-universal-debug.apk
   done
   ```
3. 每支手機開 app，給齊權限（藍牙、定位、通知），用**實驗專用帳號**登入到首頁。
   - repo 沒有現成的帳號，要自己先註冊一個：資料全部填假的，信箱用組員收得到的（例如 Gmail 的 `名字+exp@gmail.com`），註冊後要點信裡的連結完成驗證才進得了首頁。
   - 7 支手機可以共用同一個帳號：mesh 身分是每支手機各自產生的，跟帳號無關；實驗封包用的是實驗 handle，也不會帶出帳號資料。
   - 登入、驗證都要連網，所以要在開飛航模式之前做。登入過一次之後，離線開 app 等約 5 秒就會以本機資料進首頁。重新安裝 app 會清掉登入狀態，要再連網登入一次。
4. 長按首頁左上角的盾牌圖示，確認進得去「實驗工具」畫面（進不去就是裝到 release 版）。把畫面上的「本機 peerId」與型號、Android 版本填進 devices.csv。
5. 充電到 ≥ 80%。

## Session 開始（每個場地、每個半天各一次）

1. **無線電與螢幕**：先用 Wi-Fi 掃描 app 記下附近 AP 數，再開飛航模式 → 手動打開藍牙、定位；Wi-Fi 關。螢幕逾時設最長、亮度最低。
2. **時鐘偏移**：手機逐一接筆電跑 [00 §3.4](00-setup-and-instrumentation.md#34-時鐘偏移量測) 的 `offset.sh`。
3. **清 log**（手機還接著 USB 時一起做）：
   ```bash
   adb -s "$S" shell run-as com.bitchat.droid rm -f files/exp.csv
   adb -s "$S" logcat -G 16M
   adb -s "$S" logcat -c
   ```
   app 開著也可以刪；下一個事件會重建檔案並寫上表頭。
4. **拔線**，記電量。接著 USB 時是 PERFORMANCE 模式，拔掉才會回到 BALANCED。
5. 每支手機打開 app、進實驗畫面，保持前景、螢幕不關。等 **≥ 120 s** 讓 peer 清單收斂。
6. 逐支看實驗畫面的「本機」區：**電源模式要是 BALANCED（平衡）、系統省電要是「關」**；直連數符合佈置的預期（線性鏈的中間節點通常 ≥ 2）。不符合就先排除，不要開始。
   「電源模式」是 app 自己的模式，只看前景／背景、充電與電量，系統省電模式開著時它照樣顯示 BALANCED，所以兩個都要看。

## 每個 run

1. 記錄員在 runs.csv 開一列：`run_id`、位置與手機的對應（`topology`）、`battery_start`、天氣、AP 數。
2. 發送端持機人在實驗畫面設定：
   - 裝置編號：**自己的編號**
   - 筆數、間隔、TTL：照該實驗文件（多數是 50 筆、1000 ms；量多跳極限用 TTL 7）
   - 開始時間：多支手機同時發送時，總控喊一個約 1 分鐘後的時間（`HH:mm:ss`）；單一發送端可以留空＝立即開始
   - Status：安全
3. 按「開始」，確認畫面上的開始時間顯示**今天**且有倒數。顯示「明天」代表時間打錯了，按停止重設。
4. 發送中不要碰手機；持機人站在手機後方，不要擋在兩支手機之間。有人走過、螢幕被關、app 閃退等狀況，記錄員記下**牆鐘時間**。
5. 結束時，發送端畫面顯示「已完成」、「已送出 n / n」，「寫出結果」的無鏈路與 mesh 未收下都是 0。
6. **在發送端結束後 10 秒內**，接收端讀 RX 表該 handle 的 60 s 筆數，填進記錄表（見下方「已知限制」）。
7. 記錄員填 `end`、`battery_end`、`power_mode`、`anomalies`。

**當場重做的條件**（任一成立）：發送端的無鏈路或 mesh 未收下 > 0；任何一支電源模式不是 BALANCED，或系統省電開著（E4 除外）；發送中有人擋在節點之間；任何一支螢幕關掉或 app 閃退；有手機電量 < 25%（00 §2.1）。

## Session 結束

1. 手機逐一接回筆電，再跑一次 `offset.sh`（前後兩次的差就是漂移）。
2. 拉 log：
   ```bash
   mkdir -p "raw/$SESSION"
   adb -s "$S" shell run-as com.bitchat.droid cat files/exp.csv > "raw/$SESSION/$CODE.exp.csv"
   adb -s "$S" logcat -d -v epoch > "raw/$SESSION/$CODE.logcat.txt"
   ```
3. 檢查每個 `exp.csv` 的第一筆早於 session 開始、最後一筆晚於 session 結束；每 60 s 應該都有 `STAT` 列。缺的話該 session 的資料不完整。
4. `raw/` 含 peerID，**存在 repo 之外**（例如筆電的實驗資料夾與雲端備份），不要 commit。

## Day 0：工具驗收（室內）

正式實驗前，用 Day 0 確認量測工具真的能算出指標。每項都要過才出發：

| 項目 | 做法 | 通過標準 |
|---|---|---|
| 送達率與延遲可算 | A、B 相距 2 m，A→B 50 筆、B→A 50 筆（1 s、TTL 3），拉兩邊的 `exp.csv` | 每筆 `TX` 都能以 `(src, pts)` 在對方找到 `RX`；`t_RX − pts` 校正偏移後是合理的數十～數百 ms |
| 跳數可算 | A、B、C 排成一條線，A、C 互相收不到（直連數為 1），A 送 TTL 7 | C 的 `RX` 推算 `7 − ttl + 1 = 2` |
| 重複可見 | 7 支聚在一起，任一支送 50 筆 | 接收端有 `DUP` 列 |
| 螢幕關閉仍發送 | A 開始送 600 筆（1 s）後按電源鍵關螢幕，10 分鐘後再打開 | B 的 `exp.csv` 在這 10 分鐘內持續有 A 的 `RX` |
| 現場畫面即時 | 上面任一項進行時看接收端畫面 | RX 表約每秒更新 |
| 時鐘偏移腳本 | 跑一次 `offset.sh` | `phone_ms` 是 13 位數字；`%N` 不支援時另想辦法 |

現場快速核對可以用這段（只看 Health Report，`type` 為 `0x30`）：

```python
import pandas as pd
tx = pd.read_csv("A.exp.csv").query("ev == 'TX' and type == '0x30'")
rx = pd.read_csv("B.exp.csv").query("ev == 'RX' and type == '0x30'")
m = tx.merge(rx, on=["src", "pts"], suffixes=("_tx", "_rx"))
print("PDR", len(m) / len(tx))
print("hops", (m.ttl_tx - m.ttl_rx + 1).value_counts().to_dict())
print("latency p50 (ms, 未校正偏移)", (m.t_ms_rx - m.pts).median())
```

## 讀資料時要知道的實作細節

- **`TX` 不只有發送器**：本機發出的每個廣播都會記 `TX`（ANNOUNCE、同步請求、手動送的 Health Report），算送達率前先篩 `type == '0x30'`，必要時再用 handle 對應的 `src` 篩。
- **`TX`／`RELAY` 是實際寫出時記的**，`fanout` 是真的交給幾條鏈路；`fanout` 為 0 代表當下沒有鏈路可送。
- **`LINK_UP` 在確認鄰居是誰時才記**（第一個直連 ANNOUNCE），不是 GATT 一連上就記；量 T_disc 時這段差距包含在內。`n_links` 則算所有直連，包括還沒確認是誰的。
- **`STAT` 每條直連一列**：同一個 `t_ms` 的幾列是同一次快照，各列是不同鄰居的 RSSI；沒有直連時只有一列。
- **突發（間隔 0）時 `pts` 會依序順延 1 ms**，保證 `(src, pts)` 不重複；算突發延遲時會略為低估。
- **發送端的「寫出結果」**：廣播沒有回條，送出端不知道誰收到。「有鏈路」是寫出時至少交給一條 BLE 鏈路，「無鏈路」是寫出時附近沒有連上的手機（單支手機測試時全部都會是無鏈路），「mesh 未收下」是 mesh 服務沒在跑。對應 `exp.csv` 的 `TX` 列：`fanout` > 0 與 = 0。
- **`sys_saver`** 欄記下每一列當下系統省電模式是否開著（`1`／`0`），`mode` 欄則是 app 自己的電源模式，兩者互不影響。
- 離開實驗畫面不會停止發送；發送器跟著 mesh 前景服務，app 被「結束」時才會停。

## 已知限制

- 現場畫面只有最近 20 s／60 s 的視窗，**沒有累計數**。50 筆、1 s 間隔的 run 在結束後 10 秒內讀 60 s 欄還能涵蓋全部；更長的 run，畫面只能確認「還在收」，筆數以 `exp.csv` 為準。
- `STAT` 的計時器不持有 wake lock。E4 螢幕關閉、又沒在發送的手機，`STAT` 可能延遲或缺漏（每列的 `t_ms` 是實際時間）。
