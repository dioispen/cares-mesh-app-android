# 以政策層模擬作為量測工具

本專題的核心論點是「Severity-aware relay 能在壅塞的 mesh 中讓緊急 Health Report 送達」，而現行 relay 邏輯在 `networkSize <= 10` 時 relay 機率恆為 1.0，代表七人團隊能實際湊出的手機數量全部落在「等同 flooding」的區間，實機無法產生可比較的結果。因此我們以 JVM 模擬作為所有實驗數據的來源，切點選在 `PacketRelayManagerDelegate`：模擬器實作該介面並串接 N 個真實的 `PacketRelayManager` 實例，由模擬器持有拓撲、鏈路容量、延遲與遺失模型。實機 7 台手機不產生實驗結果，只產生一份校準表（每跳延遲、單鏈路送達率、最大同時連線數）餵給模擬器。

## Considered Options

- **純實機**：真實但節點數上限約 7–10，兩組對照都在 flooding 區間，圖表會是重疊的水平線。
- **純模擬（未校準）**：可跑到 N=500，但「這只是模擬」是總審第一個會被問的問題，且無法回答。
- **外部模擬器（ns-3 / OMNeT++ / Python 重寫）**：等於為封包格式新增第四套實作，直接惡化 R6 的單一真相來源問題，且量測對象不是本 App 的程式碼。

## Consequences

- 模擬跑在 `./gradlew test` 內，所有圖表可在 CI 重現，並順帶構成 R10 測試覆蓋率的主體。
- **不模擬 fragmentation**。Health Report 可能超過 100 bytes 壓縮門檻而分片，分片會放大壅塞效應；此處以「封包大小參數」近似，並由校準表決定其值。此限制須寫入報告，不應等待審查者發現。
- Severity-ordered queue（F2）必須實作在 `PacketRelayManagerDelegate` 邊界或其上層。若埋進 `BluetoothPacketBroadcaster`，模擬器無法驅動它，實驗矩陣的一半會變成不可量測。
