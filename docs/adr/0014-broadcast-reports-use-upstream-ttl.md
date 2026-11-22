# Health Report 與物資封包沿用 bitchat 的 TTL 7

Health Report 從 2026-03 起以 TTL 3 送出。這個值原本是沒有說明的寫死值；2026-11-18 四機試跑後改為具名常數 `HEALTH_REPORT_TTL_HOPS`，補上的理由是「TTL ≤ 4 才能讓每一跳都保有轉發衰減」（#14）。這個理由只推得出上限 4，推不出 3。物資封包（`SUPPLY_EXCHANGE`，0x32）又直接沿用同一個值。同一個 mesh 上，Admin Notice（0x31）與 bitchat 的其他廣播都以 `MESSAGE_TTL_HOPS`（7）送出。

#91 之後，TTL 已經不決定 Health Report 送不送得到。每台裝置把各 Reporter 最新的 Health Report 留在同步暫存 2 小時，anti-entropy 同步一跳一跳把它帶到整個連通的網路：試跑中重新連上後約 1.1–1.2 s 就補到，Reporter 離開範圍後仍驗得過簽（§7.1、ADR-0006）。TTL 只決定哪些節點在約 1 秒內經 flood 收到（每跳約 +50 ms），哪些要等同步補送（新連線約 1 s 後，已連著的鏈路每跳最多 30 s）。

我們讓 **Health Report（含 SOS）與物資封包都以 TTL 7 送出**，與上游 bitchat、Admin Notice 相同：

- `AppConstants.HEALTH_REPORT_TTL_HOPS` 改為等於 `MESSAGE_TTL_HOPS`；`SupplyExchangeBroadcast` 照舊沿用它。Relay Decision 不變。
- **代價只是 flood 的重複副本。** 收得到的節點本來就一樣多，差別只在多少節點經 flood、而不是經同步收到。在可實測的規模內（10 支以內）每一跳都 100% 轉發，TTL 3 與 7 的成本分不出來（試跑中每筆全網送出 2.41 次，每節點收到 1.6–3.1 份，§11.2）。Health Report 的頻率又很低：使用者主動送出，加上成立中的回報每 30 分鐘重發一次（ADR-0012）。沒有證據，就不偏離上游預設。
- **三種封包用同一個 TTL**，程式與報告都只需要一條規則。
- 不改線上格式。TTL 在標頭、計算簽章時以 0 代入，舊版節點與 iOS 照常轉發。

## Considered Options

- **維持 TTL 3**：唯一的理由（每一跳都保有轉發衰減）推不出 3，而且只在網路規模超過 10、轉發要擲骰時才有作用，實機量不到。
- **TTL 4**：現行門檻（`RelayPolicy.unconditionalRelayTtl` = 4）下保有每跳衰減的最大值。但這個值與門檻綁在一起，模擬器換門檻時就要跟著換；而大型 mesh 該不該保有每跳衰減，正是模擬要回答的問題，不該先在 production 決定。
- **SOS 另設較高的 TTL**：SOS 是 Health Report 上的標記（ADR-0004），共用同一個封包；7 也已經是這個 app 送出任何封包時用的最大 TTL（`MAX_TTL`）。
- **等 E1-C 的結果再決定**：E1-C 只有 7 支手機，轉發機率仍是 100%，量得到延遲的差異，量不到大型 mesh 的成本，回答不了 TTL 3 原本要處理的問題。

## Consequences

- **快的那條路變長**：flood 最遠從第 4 跳變成第 8 跳。以試跑的單跳可靠距離 140 m 外推，直線距離上限約從 560 m 變成 1120 m。第 5 到第 8 跳的節點不必再等同步補送。
- **大型 mesh 的負載**：網路規模超過 10 時，前 3 代轉發跳過依網路規模的轉發機率，成立中的回報每 30 分鐘重發也一樣。這部分交給 policy-level 模擬（ADR-0001）評估，模擬器可以經 `RelayPolicy` 換掉門檻。Severity-aware Relay（#2）若要在每一跳調整轉發機率，屆時再一起決定 TTL 與門檻。
- **TTL 仍不是隱私半徑**：同步不受 TTL 限制，TTL 3 時也不是。Broadcast Tier 的隱私靠 payload 不含可識別個人的欄位（ADR-0003、ADR-0008）。
- **實驗的定位改變**：E1-C、E2-C 不再用來決定 TTL，改為驗證本 ADR 的前提「TTL 只影響延遲」。實驗發送器以 TTL 3 送出時，第 5 跳以後的節點只能經同步收到；同步暫存每個發送者只留最新一份，所以量的是最後一筆補到的時間，不是 PDR。若 flood 範圍外的節點補不到最新一筆，前提不成立，要重新檢討。實驗發送器的 TTL 預設改為 7。
- **取代 #14 的 TTL 3**：`HealthReportBroadcastTest` 原本鎖住「轉發一次後 TTL 低於一律轉發的門檻」，改為鎖住「Health Report 的 TTL 等於 `MESSAGE_TTL_HOPS`」。
