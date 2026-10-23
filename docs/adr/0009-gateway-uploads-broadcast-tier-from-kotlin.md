# Gateway 只代傳 Broadcast Tier，由 Kotlin 端直接寫 Firestore

目前沒有任何手機會替別人上網：有網路的手機收到別人的 Health Report，只會顯示在自己的互助任務裡。舊的 `PacketUplinkManager` 從未真正上傳過，已在 `1949fdcb` 移除。整段期間都沒有網路的 Reporter，管理後台（另一組以 Flutter Web 開發，只透過 Firestore 與本專案銜接）完全看不到。

我們新增 **Gateway**：已登入、有網路的手機把經 mesh 收到、驗簽通過的 Health Report **原樣的 Broadcast Tier** 寫進 Firestore 的 `mesh_reports/{reporterHandle}`，供管理後台統計各區需要協助的人數。有三個決定：

1. **只代傳 Broadcast Tier，不加密、不帶 Detail Tier。** 後台要的是「哪一區有多少人需要幫忙」，ADR-0008 把精度提高到村里層級後，Broadcast Tier 已經足夠。
2. **由 Kotlin 端在 `MeshForegroundService` 的生命週期內直接寫 Firestore**，App 畫面關掉、手機放口袋時也能代傳。這是 CLAUDE.md「Kotlin 端不直接使用 Firestore」的有意破例。
3. **Handle 與 uid 的對應只給管理員。** Reporter 本人把自己的 Handle 與簽章公鑰登記到 `reporter_handles/{uid}/installations/{handle}`，讓後台去除與 `health_reports` 的重複；這份對應與 `mesh_reports` 都只有新增的 **Administrator**（`admins/{uid}`）讀得到。

## Considered Options

- **Reporter 用後台公鑰加密 Detail Tier 一起廣播，gateway 上傳密文**：後端解密後寫進 `health_reports/{uid}`，本人上傳與代傳落在同一處。但需要伺服器端解密（Cloud Functions 需 Blaze 方案，實驗階段不開），否則私鑰只能放在管理員瀏覽器、解密後也沒有合法的地方寫回；封包從約 20 bytes 變成 150–300 bytes，正是實驗 5 的自變數；而後台的需求根本用不到姓名與精確座標。
- **gateway 寫在 Flutter**：沿用現有 `AuthService` 與 Firestore 寫法最簡單，但 Flutter engine 綁在 `FlutterChatActivity`、沒有快取，Activity 被回收時 `InboundPacketBridge` 沒有 listener，代傳就停了。gateway 最有價值的情境（帶著回報走出災區、一連上網路就上傳）恰好是 App 不在前景的時候。
- **Flutter headless engine，由 service 喚起**：能在背景跑 Dart，但要多維護一個 engine 的生命週期。
- **Kotlin 以 Firestore REST API 寫入**：不會碰到 SDK 的離線佇列，也不必新增依賴；但要自己處理 ID token 更新與錯誤分類，且 `OkHttpProvider` 的 client 可能經過 Tor。原生 SDK 已隨 FlutterFire 進入 APK，且與 Flutter 端共用登入狀態。
- **把 Handle 寫進 `health_reports` 的 Detail Tier**：最簡單，但任何登入帳號（註冊是開放的）聽到一個 Handle 就能查出姓名與精確座標，還能把該 Handle 之後在 mesh 上的回報串成行蹤，違反 Reporter Handle「opaque」的定義。

## Consequences

- **CLAUDE.md 架構限制第 5 條要改寫**：Kotlin 端只為 gateway 使用 Firestore 與 FirebaseAuth，其餘 Firestore 存取仍在 Flutter。`app/build.gradle.kts` 要新增 `firebase-firestore` 與 `firebase-auth` 依賴（已由 BoM 鎖版本，原生程式庫早已在 APK 內）。
- **Firestore 原生 SDK 的離線佇列會寫磁碟**，與 ADR-0006「快取只放記憶體」衝突。gateway 只在網路已驗證可用時發出寫入，離線暫存放在自己的記憶體；寫到一半斷線的那一筆仍可能留在磁碟佇列，直到下次連線送出。這一小段曝光刻意接受。持久化設定不能關，Flutter 端與 Kotlin 共用同一個 Firestore 實例，SOS 畫面離線時依賴本機快取。
- **伺服器端不驗簽**：任何登入帳號都能繞過 App 直接寫 `mesh_reports`，包括用聽到的真實 Handle 寫一份更新的「安全」蓋掉真的 SOS。現在只靠 `gatewayUid` 稽核；但每份文件保留原始簽章封包與 ANNOUNCE，日後補上驗證（後台或 Functions）不必改 App。
- **管理員看得到 gateway 的大略位置**：即時 flood 收到的回報，`gatewayUid` 代表該帳號當時在那一格的 7 跳範圍內。gateway 預設開啟、設定可關，隱私政策要說明。
- **只有已登入的手機能當 gateway**，Firestore 規則需要 `request.auth`。
- **新角色 Administrator 與 Verified Rescuer 分開**：比照 `rescuers/{uid}`，只能由 Firebase console 或 Admin SDK 授予；Verified Rescuer 不因此讀得到 `mesh_reports`。
