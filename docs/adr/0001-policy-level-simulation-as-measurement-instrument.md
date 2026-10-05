# 以政策層模擬作為量測工具

**狀態：提議中，尚未定案。** 組內還沒決定要不要做模擬器。本文記錄提案內容與理由；定案後改寫這一段，未採用時也保留本文，並寫明改用的方法與原因。

本專題的核心論點是「Severity-aware relay 能在壅塞的 mesh 中讓緊急 Health Report 送達」，而現行 relay 邏輯在 `networkSize <= 10` 時 relay 機率恆為 1.0，代表七人團隊能實際湊出的手機數量全部落在「等同 flooding」的區間，實機無法產生可比較的結果。因此提議以 JVM 模擬作為 relay 策略比較的數據來源，切點選在 `PacketRelayManagerDelegate`：模擬器實作該介面並串接 N 個真實的 `PacketRelayManager` 實例，由模擬器持有拓撲、鏈路容量、延遲與遺失模型。實機手機不產生 relay 策略的比較結果，只產生一份校準表（每跳延遲、單鏈路送達率、最大同時連線數）餵給模擬器。

## Considered Options

- **純實機**：真實但節點數上限約 7–10，兩組對照都在 flooding 區間，圖表會是重疊的水平線。
- **實機，但調低 relay 機率的門檻**：讓 7–10 支手機就進入機率轉發區間，可以直接在實機上比較。代價是量到的是為實驗改過參數的行為，不是 App 實際出貨的設定；樣本只有一種規模，也無法外推到數十、數百人的災區。
- **純模擬（未校準）**：可跑到 N=500，但「這只是模擬」是總審第一個會被問的問題，且無法回答。
- **外部模擬器（ns-3 / OMNeT++ / Python 重寫）**：等於為封包格式新增第四套實作，直接惡化 R6 的單一真相來源問題，且量測對象不是本 App 的程式碼。

## 定案前要回答的問題

- 有沒有人力在 M1 建出模擬器（PLAN.md 的 R12）。不做的話，PLAN.md 的實驗 1～8 要改由什麼產生數據。
- 不做模擬器時，核心論點要怎麼證明：改用上面「調低門檻」的實機比較，或是把論點縮小為實地可用性（距離、穿透、負載上限、節點流失）。
- E3（[03-flooding-tolerance.md](../experiment/03-flooding-tolerance.md)）目前設計成量模擬器的鏈路容量參數。若改用實機比較 relay 策略，E3 要在實驗前重新設計。

不論是否採用，實機實驗 E1～E5 量到的鏈路參數（[calibration-table.md](../experiment/calibration-table.md)）都會用在報告中。

## Consequences（若採用）

- 模擬跑在 `./gradlew test` 內，所有圖表可在 CI 重現，並順帶構成 R10 測試覆蓋率的主體。
- **不模擬 fragmentation**。Health Report 可能超過 100 bytes 壓縮門檻而分片，分片會放大壅塞效應；此處以「封包大小參數」近似，並由校準表決定其值。此限制須寫入報告，不應等待審查者發現。
- Severity-ordered queue（F2）必須實作在 `PacketRelayManagerDelegate` 邊界或其上層。若埋進 `BluetoothPacketBroadcaster`，模擬器無法驅動它，實驗矩陣的一半會變成不可量測。
