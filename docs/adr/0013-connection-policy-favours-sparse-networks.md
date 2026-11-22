# 連線策略以稀疏的災區網路為準

2026-11-18 的四機試跑（[報告](../experiment/results/2026-11-18_four-phone-trial.md)第 8、10、12.1、13.3 節）顯示，決定 Rescuer 能不能及時收到 Health Report 的，是「連不連得上」，不是鏈路品質：

- **連線撐到約 170 m，重新連上卻要走回約 15 m。** `BluetoothGattClientManager` 只對掃描 RSSI 不低於 `PowerManager.getRSSIThreshold()` 的鄰居發起連線：PERFORMANCE −95、BALANCED −85、POWER_SAVER −75、ULTRA_LOW_POWER −65 dBm。這組門檻來自上游 bitchat 2025-07 為人潮密集處做的省電改動。雙方早在 −84 ～ −106 dBm 就互相掃到，只是 App 不連；重連因此晚了 21–38 s，漏收 118 筆。
- **弱鏈路其實可靠。** Run 1 在 −93 ～ −99 dBm 仍逐筆直連送達，直到斷線前 6 s；Run 2 邊緣鏈路的 PDR 是 96.9%；5772 筆應收中只有 38 筆是鏈路本身掉的。
- **8 個連線名額從來沒用滿**；超過上限時淘汰的是最舊的連線，不是最弱的。已連線 peer 的 RSSI 停在連上當下的值，因為 `handleScanResult` 遇到已連線的 peer 就提早返回。
- **背景時幾乎連不上。** 電量 > 20% 時是 POWER_SAVER，門檻 −75 dBm；沒有直連時每 60 s 只掃 1 s，而且用 `SCAN_MODE_LOW_POWER`（控制器自己每 5 s 只聽約 0.5 s），1 s 的窗可能什麼都聽不到。廣播用 `ADVERTISE_MODE_LOW_POWER` + `ADVERTISE_TX_POWER_LOW`，經過的 Rescuer（通常在前景，是發起連線的一方）能聽到受困者手機的距離也跟著縮短。同步本身每 30 s 一次、不分電源模式，背景的瓶頸是連不連得上。
- **B 這次沒有啟動前景服務**（`shouldStartForeground=false`：背景執行關閉或權限不全），App 進背景就可能被系統凍結，使用者卻不知道。

災區的手機稀疏、多半熄屏放在口袋、電量有限；Rescuer 常常晚到，而且只是從旁經過。問題是連線太少，不是太多。我們決定：

1. **發起連線的 RSSI 門檻依直連數與名額決定**（`ConnectionRssiThreshold`，單位 dBm）：

   | 情況 | PERFORMANCE | BALANCED | POWER_SAVER | ULTRA_LOW_POWER |
   |---|---|---|---|---|
   | 孤立：直連的 peer 少於 2 個 | −115 | −115 | −115 | −115 |
   | 名額快滿：連線數 ≥ 上限 − 1 | −95 | −85 | −75 | −65 |
   | 其他 | −115 | −115 | −115 | −95 |

   −115 dBm 低於手機 BLE 的接收靈敏度（約 −100 ～ −106 dBm；試跑掃到最弱的是 −106），意思是**聽得到就連**。這是使用者的決定：稀疏的災區網路裡，弱鏈路在試跑中已證明可靠。孤立的手機只能靠連線把自己的 Health Report 送出去，所以不分電源模式。電量 ≤ 10% 且已有直連時維持 −95，多連線只會多耗電。名額快滿時維持上游的嚴格門檻，這一層是人潮密集處主要的保護。

   直連數算的是 **peer，不是連線**：兩支手機常常互為 client 與 server，各有一條連線。連線要等識別出對方（掃描的 service data，或第一個驗證過的 ANNOUNCE）才算；連進來的連線在最初約一秒還沒識別，這段期間門檻偏向「連」。

2. **以邊緣連線保護取代遲滯**（`EdgeConnectGuard`）。門檻放到 −115 之後，「發起連線」與「斷線」（約 −95 ～ −100 dBm）之間已經沒有遲滯。遲滯原本擋掉的是註定失敗的邊緣連線：`connectGatt(autoConnect = false)` 失敗前會在堆疊裡卡約 30 s、佔住控制器，同一位址在這期間再呼叫一次會洩漏 client interface、造成 status 133。現在：
   - **每個位址同時只有一個連線嘗試。** `MeshConnectionTracker` 的待連線項目 10 s 後就算過期，不能再因此放行第二次 `connectGatt`。
   - **每個嘗試都有逾時。** 掃描 RSSI 低於 −95 dBm 的弱候選，10 s 內沒有連上並完成 MTU 協商就取消（`disconnect()` + `close()`，清掉待連線項目）。其他嘗試的逾時是 35 s，比堆疊自己的長，只用來接住永遠不來的 callback。
   - **弱候選失敗後，對該位址退避** 15 s → 30 s → 60 s，之後維持 60 s；連上，或聽到對方比失敗時強 10 dB 以上，就清除。

3. **名額滿時以強換弱**（`WeakLinkReplacement`）。滿了以後，候選若比最弱的 client 連線強 10 dB 以上，就斷開那條、改連候選；兩次替換至少相隔 30 s，避免強度相近的候選輪流互換。只有已識別、尚未直連的 peer 能這樣換，免得同一個鄰居的第二條連線擠掉另一個鄰居。超過上限時的淘汰（`getConnectionsToEvict`）也改成先淘汰最弱的，同強度時淘汰最舊的，強度不明的排在已知的之後；角色上限與「優先淘汰 client」不變。

4. **已連線 peer 的 RSSI 保持新鮮。** 已連線的 peer 仍在廣播，掃描結果照樣記下，依位址、也依 service data 裡的 peerID（對方連進來時用的位址與廣播位址不同）。`getBestRSSI` 取最新的一筆，「最弱」的判斷因此用的是現在的強度。

5. **背景、沒有直連時加長掃描**：每 30 s 掃 4 s，這段用 `SCAN_MODE_BALANCED`（以前每 60 s 掃 1 s、`SCAN_MODE_LOW_POWER`），電量 ≤ 10% 時也一樣。有直連時維持每 30 s 掃 1 s；前景不變。

6. **沒有直連時提高廣播**：`ADVERTISE_MODE_BALANCED` + `ADVERTISE_TX_POWER_HIGH`（PERFORMANCE 本來就是 LOW_LATENCY + HIGH，不降）；ULTRA_LOW_POWER 改為 `ADVERTISE_MODE_LOW_POWER` + `ADVERTISE_TX_POWER_MEDIUM`。有直連時維持各模式原本的設定。廣播設定一變就重新開始廣播（以前只在電源模式改變時），並等 3 s 沒有再變才重啟，避免直連忽有忽無時反覆重啟。

7. **前景服務沒在跑時告訴使用者。** 首頁顯示提示，說明原因（背景執行已關閉、缺少權限、背景服務沒有在執行），並提供一鍵修正；可以關掉，原因改變或下次開 App 時再出現。

所有數字都是具名常數（`ConnectionRssiThreshold`、`EdgeConnectGuard`、`WeakLinkReplacement`、`PowerProfileResolver`），實驗後直接調整。

## Considered Options

- **維持上游門檻**：人潮密集處能省名額與電量，但這次已量到代價：Rescuer 要走到約 15 m 內才連得上，背景時更近；只從 50 m 外經過的 Rescuer 可能根本不會連上。
- **放寬到約 −92 dBm，保留較小的遲滯**：原本的提案，發起連線仍比斷線點嚴。使用者選擇不設遲滯，改以邊緣連線保護處理遲滯原本要防的事。
- **一律 −115（或 −95），不分情況**：最簡單，但人多時新連線會塞滿名額，強鄰居只能等淘汰。名額快滿時維持嚴格，保留人潮密集處的保護。
- **只對近期見過的 peer 放寬**：要多維護一份「見過」的狀態，也幫不了第一次經過的 Rescuer。
- **背景時連續掃描**：發現最快，但耗電最多，Android 也會在背景節流掃描。先用 4 s / 30 s 的窗，看 E4 的結果再調。
- **前景服務沒啟動時自動打開背景執行**：背景執行是使用者可以關掉的設定，自動改回會違背使用者的選擇；改為提示並提供一鍵開啟。

## Consequences

- **耗電還沒量過。** 多出來的連線（維持連線的固定開銷、flooding 每多一條連線就多寫一次、弱連線的重傳與重試）、背景較長的掃描窗與較高的廣播功率都會多耗電。要由 [E4](../experiment/04-power-and-endurance.md) 驗證：0、2、4 條連線各自每小時的耗電，以及熄屏背景下的連線建立時間與同步間隔。
- **範圍邊緣會有更多勉強的連線**，可能反覆斷線重連。邊緣連線保護限制了重試的頻率，斷線重連本身仍會發生。
- **人潮密集處只靠「名額快滿時嚴格」與「以強換弱」保護。** 被換掉的 peer 若轉而主動連進來，會擠掉另一條 client 連線。要由 [E3](../experiment/03-flooding-tolerance.md) 確認人多時名額不會被弱連線塞滿，也不會反覆替換。
- **[E5-C](../experiment/05-node-failure-and-mobility.md#e5-c-救援者走入與走出約-40-分鐘) 改量 −115 與舊的 −85 dBm 下，Rescuer 走進來多遠會連上**，前景與背景各一次。
- **前景沒有直連時，廣播功率也會從 MEDIUM 變成 HIGH。** 距離類實驗（E1、E2、E5-C）要注意：斷線後手機變成孤立、廣播變強，重連的距離可能比斷線前的廣播範圍遠。[00 §2.1](../experiment/00-setup-and-instrumentation.md#21-電源模式最大的干擾因子) 的電源模式表已更新。
- **「有沒有直連」（`AppStateStore.directPeers`）只在送出 ANNOUNCE 時重算**：連上後一兩秒內就會更新，斷線後最多要等一個 announce 間隔（背景 60–300 s）。這段期間掃描與廣播用的是舊的判斷。
- **不改封包格式，與 iOS 相容。** iOS 的廣播沒有 service data，掃描時認不出 peer，所以 iOS 鄰居不會觸發以強換弱。
