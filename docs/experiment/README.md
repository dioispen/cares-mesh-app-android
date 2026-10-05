# 實機實驗計畫

CARES Mesh 以 7 支 Android 手機進行的實機實驗設計。每份文件都包含目的、依程式碼推得的預期、場地佈置、步驟、要記錄的指標，以及可以直接印出帶到現場的空白記錄表。

## 與 ADR-0001 的關係

[ADR-0001](../adr/0001-policy-level-simulation-as-measurement-instrument.md) 已決定：Severity-aware relay 與 flooding 的比較只在 JVM 模擬中進行。原因是 `networkSize <= 10` 時 relay 機率恆為 1.0，7 支手機全部落在 flooding 區間。因此這裡的實驗**不比較 relay 策略**，只回答兩類問題：

1. **校準**：模擬器需要的實機參數，例如每跳延遲、單鏈路送達率、最大同時連線數，彙整於 [calibration-table.md](calibration-table.md)。
2. **實地可用性**：手機 mesh 在真實環境能涵蓋多遠、穿得過什麼障礙、多大負載會崩潰、救援者走進範圍時看得到什麼。這些是模擬器無法自己回答、審查時一定會被問的問題。

## 與 PLAN.md 實驗編號的關係

[PLAN.md §2](../PLAN.md) 的「實驗 1～9」是模擬實驗的編號。本目錄的 **E1～E5 是實機實驗的代號**，兩者不同，引用時不要只寫「實驗 1」。對應關係如下：

| PLAN.md | 本目錄 |
|---|---|
| 實驗 9：實機校準驗證 | E1～E5 全部。產出的 [calibration-table.md](calibration-table.md) 交給模擬器，模擬結果再回頭與實機量測值比對 |
| 實驗 7：拓撲敏感度（叢集／線狀） | E3 的 T1 團簇與 T2 線狀、E1-C 線性鏈，提供模擬的實機對照 |
| 實驗 8：節點流失與移動 | E5，提供模擬的實機對照 |
| 實驗 1～6 | 不在實機上做（依 ADR-0001），只使用這裡的校準參數 |

## 實驗清單

| 代號 | 文件 | 回答的問題 | 手機數 | 場地 | 預估時間 |
|---|---|---|---|---|---|
| E1 | [01-multihop-line.md](01-multihop-line.md) | 單跳能傳多遠？7 支手機排成一條線，能把 Health Report 送多遠？每多一跳增加多少延遲與遺失？ | 2 → 7 | 空曠直線 ≥ 150 m | 2 個半天 |
| E2 | [02-building-penetration.md](02-building-penetration.md) | 牆、樓板、口袋、瓦礫各會吃掉多少訊號？從地下室送到戶外需要幾個中繼？ | 2 → 7 | 多層 RC 建築 | 半天 |
| E3 | [03-flooding-tolerance.md](03-flooding-tolerance.md) | 發送量多大時送達率與延遲會崩潰？崩潰後多久恢復？flooding 的重複傳輸成本多高？ | 7 | 室內空地 | 半天 |
| E4 | [04-power-and-endurance.md](04-power-and-endurance.md) | 背景、低電量、充電各讓發現與延遲慢多少？背景下會不會被系統殺掉？手機能撐多久？ | 2–7 | 室內 | 半天 + 續航測試 |
| E5 | [05-node-failure-and-mobility.md](05-node-failure-and-mobility.md) | 中繼消失時掉多少封包、多久恢復？救援者走進範圍時收得到什麼？早先送出的 Health Report 會不會補送？ | 7 | 與 E1 同場地 | 半天 |

## 執行順序

```
前置工作（00）
   │
   ▼
E1-A 裝置差異 ──► E1-B 單跳距離標定 ──► E1-C 七機線性鏈 ──► E5（沿用 E1-C 的間距）
                        │
                        ├──► E2（以 d_rel 為距離基準）
                        └──► E3（線狀拓撲的間距沿用 E1-C）

E4 的低電量條件需要把手機耗到 20% 以下，排在最後。
```

E1-B 量出的**可靠單跳距離 `d_rel`** 是後續所有實驗的間距基準，必須最先完成。

## 建議時程

| 天 | 內容 |
|---|---|
| Day 0（室內） | 完成前置工作；兩支手機互發 50 筆試跑，確認 log 可以對齊、時鐘偏移量測可用 |
| Day 1（戶外） | E1-A、E1-B |
| Day 2（戶外） | E1-C、E5、E3-D（線狀拓撲的 flooding） |
| Day 3（建築） | E2 |
| Day 4（室內） | E3-A～C、E4-A～C（低電量條件放最後）；E4-D 續航測試可以隔夜跑 |

## 前置工作（開始實驗前必須完成）

詳見 [00-setup-and-instrumentation.md](00-setup-and-instrumentation.md)。

最關鍵的是：**原本的程式碼沒有能對齊封包的 log**。Flutter 端每位 Reporter 只顯示最新一筆，bridge 的 log 也沒有 sender、TTL、封包時間戳，因此送達率、延遲、跳數這三個核心指標都算不出來。實驗開始前需要先補上（[#70](https://github.com/dioispen/cares-mesh-app-android/issues/70)）：

- [x] 結構化實驗 log（`CARES_EXP`），同時寫入 logcat 與 app 私有目錄的檔案
- [x] 實驗用自動發送器：可設定筆數、間隔、TTL、開始時間，螢幕關閉後仍持續發送
- [x] 現場即時計數畫面：顯示最近收到的實驗封包數，方便現場判斷要不要重做
- [ ] 時鐘偏移量測腳本試跑（Day 0）

當天的操作順序見 [field-day-runbook.md](field-day-runbook.md)。

## 指標總覽

指標的定義與計算方式見 [00 §4](00-setup-and-instrumentation.md#4-共用指標定義)，各實驗專屬的指標寫在各自的文件中。

| 指標 | E1 | E2 | E3 | E4 | E5 |
|---|:-:|:-:|:-:|:-:|:-:|
| 送達率 PDR | ● | ● | ● | ● | ● |
| 端到端延遲 L（p50 / p95） | ● | ● | ● | ● | ● |
| 跳數 h（由 TTL 推算） | ● | ● | ● |  | ● |
| 每跳延遲 ΔL | ● |  |  |  |  |
| RSSI / 衰減 ΔRSSI | ● | ● |  |  |  |
| 可靠／最大單跳距離 d_rel、d_max | ● | ● |  |  |  |
| 發現時間 T_disc | ● | ● |  | ● | ● |
| 鏈路建立／恢復時間 |  |  |  |  | ● |
| 重複率 R_dup、傳輸成本 C_tx |  |  | ● |  | ● |
| 佇列滿 QFULL、斷鏈 LINK_DOWN | ● |  | ● |  | ● |
| 飽和負載 λ_sat、排空時間 T_drain |  |  | ● |  |  |
| 背景存活時間 |  |  |  | ● |  |
| 耗電率（%/h） |  |  | ● | ● |  |

## 文件導覽

| 檔案 | 內容 |
|---|---|
| [00-setup-and-instrumentation.md](00-setup-and-instrumentation.md) | 裝置登錄、控制變因、量測工具規格、時鐘同步、log 收集、共用指標定義、統計慣例 |
| [field-day-runbook.md](field-day-runbook.md) | 實驗當天的角色、安裝、session 與每個 run 的操作順序、Day 0 工具驗收 |
| [01-multihop-line.md](01-multihop-line.md) | E1 多跳線性鏈 |
| [02-building-penetration.md](02-building-penetration.md) | E2 建築物穿透 |
| [03-flooding-tolerance.md](03-flooding-tolerance.md) | E3 Flooding 耐受度 |
| [04-power-and-endurance.md](04-power-and-endurance.md) | E4 電源狀態與續航 |
| [05-node-failure-and-mobility.md](05-node-failure-and-mobility.md) | E5 節點失效與移動 |
| [calibration-table.md](calibration-table.md) | 交給模擬器的校準表 |
| [templates/devices.csv](templates/devices.csv) | 裝置登錄樣板 |
| [templates/runs.csv](templates/runs.csv) | 每次 run 的條件記錄樣板 |

原始 log 含 peerID，**不進 repo**。整理後以裝置代號 A–G 表示的結果放在 `docs/experiment/results/<日期>_<實驗代號>.md`。
