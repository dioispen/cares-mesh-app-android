# 驗 Health Report 的 signing key 與在線 peer 分開保存，過舊的 ANNOUNCE 只用來學 key

#91 讓中繼保留每個 Reporter 最新的 Health Report 2 小時，經 anti-entropy 同步補送給後來才進入範圍的人。但接收端原本只用 `PeerManager` 在線 peer 的 signing key 驗簽，而 key 在 Reporter 3 分鐘沒消息後就隨 peer 一起移除；ANNOUNCE 又有 10 分鐘的時間差上限。結果是 Reporter 離開約 3 分鐘之後，補送的回報送得到卻沒人收得下（#95）。

我們把**驗 Health Report 用的 key 與在線 peer 分開**：

- **驗簽 key 快取**（`HealthReportSigningKeyCache`）：每份通過驗證的 ANNOUNCE 都把其中的公鑰與**整份已簽章的 ANNOUNCE** 記下，保留 `HEALTH_REPORT_RETENTION_MS`（2 小時），上限 1000 筆。`PeerManager` 沒有 key 時，**只有 HEALTH_REPORT** 改查這份快取。
- **過舊的 ANNOUNCE 只用來學 key**：超過 10 分鐘時間差、但身分綁定（peerID ＝ Noise 公鑰的雜湊）與簽章都正確的 ANNOUNCE，以及經同步送來（TTL 0）且超過 3 分鐘的 ANNOUNCE，只寫入快取，不建立或更新 peer、不更新 last-seen、不轉發。
- **ANNOUNCE 隨 Health Report 逐跳傳下去**：中繼持有某人的 Health Report 期間保留他的 ANNOUNCE；同步集合裡沒有時（只聽過過舊的那份），就從快取取出原封包，先於回報送出。下一跳自己驗 A 的簽章，不必相信中繼。為了不讓收到的人誤以為 A 在線，只轉送比 peer 逾時（3 分鐘）還舊的快取 ANNOUNCE。

不改線上格式，與 iOS 相容。

## Considered Options

- **只延長中繼保留 ANNOUNCE 的時間**：接收端仍以 10 分鐘時間差拒收，超過就沒用；未超過的則會把早已離開的 Reporter 重新列為在線 peer。
- **只在快取記 key、不保留 ANNOUNCE**：補送只能多走一跳。A → B → C → E 中，C 驗得過，但 C 沒有 ANNOUNCE 可以交給從沒見過 A 的 E。
- **在 ANNOUNCE 上註記「這是補送的」**：簽章涵蓋 TTL 以外的所有欄位，加任何註記 A 的簽章就驗不過。能用的只有 TTL，而同步回應本來就是 TTL 0。
- **Health Report 自帶公鑰**：每份多 64 bytes，不再依賴 ANNOUNCE，走幾跳都行。但 payload 要升版本，舊版 App 一律拒收新回報；信任程度與本方案相同，卻沒有額外好處。
- **自我認證的 Reporter Handle**（handle ＝ 專用金鑰公鑰的雜湊，回報以該金鑰簽名）：驗證與 mesh 身分完全脫鉤，中繼也無法竄改。驗證最強，也能順帶處理下述的隱私問題，但要改寫 ADR-0003 的 handle 定義與 Flutter 端產生 handle 的方式，改動最大。留待與隱私問題一併規劃。
- **快取存到磁碟**（iOS bitchat 的做法）：重開 App 後仍能驗。但快取會累積成「誰在何時出現在附近」的長期紀錄，而 peerID 由持久化的 Noise 靜態公鑰推出、跨重開不變，因此只放記憶體。

## Consequences

- **信任程度等同第一次見面就相信（TOFU）。** ANNOUNCE 證明的是「持有這把 signing key 的人簽了它」，signing key 與 Noise 公鑰的綁定在初次見面時無從驗證，對從沒見過 Reporter 的接收端，偽造者可以用自己的 signing key 冒用他的 peerID。這與現在第一次收到任何人的 ANNOUNCE 時相同，本方案放寬的只是 ANNOUNCE 的新鮮度。與在線 peer 或已驗證的持久化狀態衝突的 ANNOUNCE 照舊拒收；只與快取衝突時，快取保留先記下的 key、不被覆蓋（除非新 key 與已驗證的持久化狀態相符），ANNOUNCE 本身照既有規則處理。
- **快取只能用於 Health Report。** 不可拿來驗公開訊息、LEAVE、檔案或語音，也不可用於 peer 列表、私訊或 Noise 握手：那些都隱含「對方此刻在附近」或需要更強的身分保證。之後若有其他廣播類型也需要補送，要另外評估。
- **TTL 0 且超過 3 分鐘的 ANNOUNCE 一律只學 key，包括正常 flood 的最後一跳。** ANNOUNCE 從 TTL 7 出發，轉發 7 次到達時也是 TTL 0。若剛好在發送者第 8 跳、而這份 ANNOUNCE 已經 3–10 分鐘舊（通常代表發送者手機時鐘慢了 3–10 分鐘），對方不會出現在 peer 列表，其公開訊息也驗不過，直到收到 TTL 大於 0 的副本為止。兩個條件須同時成立，極少發生；換來的是補送期間不會把早已離開的 Reporter 誤顯示為在線。**這條規則不是多餘的**，拿掉就會出現後者。
- **ANNOUNCE 帶著暱稱，會隨 Health Report 傳得更遠、留得更久。** Health Report 封包的 senderID 就是裝置的 peerID，範圍內任何人都能經由 ANNOUNCE 把 Reporter Handle 連到暱稱與裝置。這是 ADR-0003 沒有涵蓋到的既有問題，本方案讓它的曝光面變大（多跳、最長 2 小時）。目前刻意接受，處理方式見上面的自我認證 Reporter Handle。
- **時間差上限從「拒收」變成「分流」。** `AnnouncementIdentityValidator.verify` 的 10 分鐘上限仍決定一份 ANNOUNCE 能不能證明「對方在線」；`verifyStale` 對 2 小時加 10 分鐘以內、更舊的 ANNOUNCE 只回答「這把 key 屬於誰」。未來調整任一個保存期限，三者（Health Report 保留期限、快取保留期限、`verifyStale` 的年齡上限）要一起看。
