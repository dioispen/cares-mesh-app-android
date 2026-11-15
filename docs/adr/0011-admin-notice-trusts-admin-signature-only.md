# 管理端公告只信任管理端簽章，以新封包類型 0x31 傳送，不要求裝置簽章

管理端要能把公告（廣播、單播、組播）送到用戶端：有網路的用戶端從 Firestore 收到後注入 BLE mesh，再傳給離線的人。離線的接收者碰不到 Firestore，Firestore rules 對他沒有意義；而 mesh 封包上的裝置簽章只證明「哪支手機送出」，任何人改一版 App 就能在 mesh 上發一則假的撤離令。

我們決定：

- **信任只來自管理端簽章。** 管理端以 Ed25519 私鑰簽整份公告 payload，App 內建管理端公鑰（附 key ID）。每個中繼與接收者都先驗管理端簽章，驗不過就不轉送、不顯示。從 Firestore 收到的副本同樣要驗，不因為 rules 擋過就相信。
- **新增封包類型 `ADMIN_NOTICE (0x31)`，不沿用 `HEALTH_REPORT (0x30)`。** 0x31 不在 `SecurityManager.verifyPacketSignature` 強制驗裝置簽章的名單裡，Gateway 注入時也不附裝置簽章。
- **外層封包是正規化的。** senderID 填公告的 messageId、timestamp 填 issuedAt、不帶 recipient 與裝置簽章，所以不同 Gateway 注入的同一則公告是**同一個封包**：`PacketIdUtil` 雜湊 type、senderID、timestamp 與解壓縮後的 payload，算出的封包 ID 相同，與傳輸層壓縮無關。既有的封包去重與 gossip sync 的 GCS 比對因此直接生效，舊版 App 也會把它們當成同一個封包。接收端要求 senderID 等於 messageId、timestamp 等於 issuedAt，不符就丟棄。

格式與處理規則見 `docs/ADMIN_NOTICE_V1.md`。

## Considered Options

- **沿用 0x30，加 `BroadcastContentTag` 0x02**：不用新類型，但 0x30 強制驗裝置簽章，key 要從 Gateway 的 ANNOUNCE 學。經 gossip sync 補送時 Gateway 早已離開，會重演 #95，得把 ADR-0006 只限 Health Report 的 key 快取擴大到公告。而裝置簽章對公告沒有任何信任價值，每份還多 64 bytes。
- **裝置簽章與管理端簽章都要**：同上的 key 快取問題，多 64 bytes，信任程度沒有增加。不同 Gateway 的副本也會因 senderID、timestamp、簽章不同而變成不同封包，各自洪泛。
- **相信 Gateway**：任何登入帳號都能當 Gateway，等於沒有保護。
- **不驗證、標示「未經驗證」**：緊急時刻沒有人會分辨這個標示。

## Consequences

- **這是第一個不以裝置簽章為信任依據的公開封包類型。** 0x31 的 senderID 不是 peer：凡是把 senderID 當成 peer 使用的程式（peer 列表、last-seen、拓撲、實驗 log 的發送者欄位，以及 `PacketProcessor` 依 senderID 建立、只在 peer 斷線時清掉的 actor）都要排除 0x31。之後若有其他類型想比照，必須自帶端到端簽章，不能只是「不驗」。
- **ADR-0006 不變。** key 快取仍只用於 Health Report。
- **舊版 App 會盲目轉送 0x31，包括偽造的。** `PacketProcessor` 對未知類型不驗簽、照常轉送。偽造公告經過舊版節點時仍會擴散，但到新版節點就被丟棄，也不會在任何版本上顯示。換來的是更新期間 mesh 覆蓋範圍不縮水。
- **私鑰外洩只能靠改版 App 撤銷。** v1 所有操作者共用一把 key（keyId 0x01），外洩後在使用者更新之前，持有者能發任何公告；mesh 上也分不出是哪位操作者發的，只能從 Firestore 的 `createdBy` 追查。App 預留 key ID，換 key 時新舊並存一個版本。
- **管理端簽章與 Firestore rules 是兩道獨立的防線。** rules 寫錯讓非管理員寫進 `admin_notices`，假公告仍過不了簽章；反過來私鑰外洩時，rules 也擋不住從 mesh 直接注入的偽造公告。
- **正規化的封包讓 Gateway 的 senderID 不出現在 mesh 上。** 旁人無法從公告封包得知是哪支手機有網路、替大家注入。因此「代傳附近的求救與回報」開關只管 Gateway 送出 mesh 的方向，不管注入。
- **Kotlin 端使用 Firebase 的範圍擴大到公告。** ADR-0009 只為 Gateway 送出 mesh 的方向破例；公告的 listener、注入與回條也要在 `MeshForegroundService` 裡跑，畫面關著時才收得到、注入得了。CLAUDE.md 與 AGENTS.md 的架構限制第 5 條要改寫成涵蓋兩個方向。Firebase 程式碼仍不進 `mesh/`，listener 透過 hook 把公告交給協定層。
