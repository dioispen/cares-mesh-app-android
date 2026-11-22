# 舉著 SOS 或受傷的 Health Report，由 Reporter 的裝置每 30 分鐘重發

#91 讓每支手機在同步暫存裡保留每個 Reporter 最新的 Health Report 2 小時（`HEALTH_REPORT_RETENTION_MS`）。年齡是「本機時鐘 − 封包標頭的時間戳」，時間戳在簽章範圍內，同步補送只把 TTL 改成 0，不會延長；所以整個網路對同一筆回報的到期時間相同。Health Report 又只在使用者於 Health 畫面或 SOS 畫面送出時產生。

SOS 依定義會一直舉著，直到撤回或宣告安全（ADR-0004）；輕傷、重傷也是 Reporter 送出下一筆之前一直成立的陳述。但 Reporter 若之後沒再操作手機，2 小時後他的回報就從所有手機的暫存消失，之後才走進範圍的 Rescuer 再也收不到。救援可能數小時後才到，而最需要救援的人，正是最可能無法再操作手機的人（2026-11-18 四機試跑 13.3 P1-4）。

我們讓 **Reporter 自己的裝置重發成立中的回報**：

- **何時重發**：Reporter 最新一筆自己的 Health Report（P0-3 保存的那一筆，`OwnHealthReportKeeper`）舉著 SOS，或 Status 為輕傷、重傷時，每 30 分鐘（`STANDING_REPORT_RESEND_INTERVAL_MS`）以**新的封包時間戳重新簽章**，經 `HealthReportBroadcast.send` 發送一次：照常 TTL 3 flood、放進同步暫存，並成為新的「最新一筆」。30 分鐘遠小於 2 小時的保留期限，一次重發沒人收到、或等待被 Doze 拉長，回報也不會在下一次重發前到期。
- **payload 原封不動**，包括 `reportTime` 與位置：Rescuer 仍看得到 Reporter 實際做出這個陳述的時間；位置不重新取得。
- **在 `MeshForegroundService` 裡跑**（`StandingReportRebroadcaster`），不依賴 Flutter 畫面。下一次發送排在「上一次發送的封包時間戳 + 30 分鐘」：app 或服務重啟既不會連發、也不會漏掉一次；Reporter 手動送出一筆就是重新起算。平時只有一個 delay；保存的回報一變就從新的那筆重算，沒有輪詢。只有該發卻因為 mesh 沒在跑而送不出去時，才每 5 分鐘再試一次。
- **何時停止**：最新一筆是「安全」且沒有 SOS（Reporter 送出新的一筆就取代舊的，每次醒來都重新判斷），或保存的回報被清除（panic 換身分）。成立中的回報保存到超過 2 小時也不刪，手機關機數小時後重新開機，仍會馬上重發一次；其餘回報照 P0-3 到期就刪。
- **實驗 Handle 的回報不重發**：背後沒有人在等救援，重發只會干擾下一場量測。
- **接收端以（Reporter Handle、`reportTime`）認出同一則陳述**：重發是新的封包 ID、同一份 payload。`MessageHandler` 只把同一則陳述交給聊天 delegate 一次（聊天列本來就依 id 去重，但每交一次都會再震動一次）；Flutter 的 Health 畫面本來就依 Handle 與 `reportTime` 合併（`mergeBleReport`），Mutual-aid Task 清單每個 Handle 一筆，Rescuer 的進度也依 Handle 保留，而且 `MutualAidTaskBoard` 只在 `reportTime` 較新時套用重開規則，已完成的任務不會因重發而重開，所以重發照轉，第一份送達時沒開著的畫面要靠它才看得到；Gateway 依 `reportTime` 自行略過已上傳的。Health Report 本來就不觸發通知：Android 只通知私訊與提及，Flutter 端沒有回報通知。

一併處理時鐘：各機用自己的時鐘判斷到期，時鐘快了幾小時的手機送出的回報，會在別人的同步暫存裡多留幾小時，而且作為該 Reporter 最新的一筆，會蓋住他之後真正的回報。同步暫存因此**拒收時間戳比本機時鐘快超過 10 分鐘的 Health Report**（`HEALTH_REPORT_MAX_FUTURE_SKEW_MS`）。試跑量到四支手機之間最多差 1.3 s；10 分鐘與 ANNOUNCE 的時間差上限（`AnnouncementIdentityValidator`）、`mesh_reports` 規則對 `reportTime` 的容忍相同，任何回報最多留 2 小時 10 分鐘。這個檢查**只在同步暫存**，不在接收與轉發路徑：即時 flood 有 TTL 與去重，壞時鐘的害處只在暫存裡留太久；在接收端丟掉，等於因為手機時鐘錯了就不顯示一個真實的 SOS。

不改線上格式，與 iOS 相容。

## Considered Options

- **依 Severity 延長保留期限**（例如 SOS 保留 12 小時）：只有更新過的 Android 節點會照新期限保留，舊版與 iOS 節點仍 2 小時就丟，補送鏈在它們那裡斷掉；期限再長，回報終究會到期，只是把問題往後推。偽造或早已過時的 SOS 也會留得一樣久。拒絕。
- **不處理**：SOS 2 小時後從網路上消失，正好落在最需要它的情境。
- **兩者都做**：延長期限的好處被上述理由抵銷，又多一組必須一起調整的期限（ADR-0006 列出的三者再加一個）。重發已足以讓回報不消失。
- **重發時更新 `reportTime` 或位置**：Rescuer 會以為 Reporter 剛剛還能操作手機、位置是最新的；重新取得位置也要在背景開 GPS。
- **在 Flutter 端定時重發**：畫面關閉、Flutter engine 不在時不會跑，而那正是 Reporter 無法操作手機的時候。

## Consequences

- **電量**：每位舉著 SOS 或受傷的 Reporter，每 2 小時多約 4 次 flood（TTL 3），範圍內每台手機各轉發一次。delay 以開機後的 uptime 計，CPU 休眠時不前進：Doze 下實際間隔可能長於 30 分鐘（試跑 12.1 中，60 s 一次的 `STAT` 計時器被拉長到 1–5 分鐘）。每次醒來都以牆上時鐘重算，不會因此連發。若實測延遲到接近 2 小時，改用 `AlarmManager.setAndAllowWhileIdle`。
- **隱私**：裝置會持續廣播 Broadcast Tier 的精確座標（ADR-0008），範圍內的人在 Reporter 宣告安全之前，都知道他確切在哪裡，也知道這支手機還開著；ADR-0006 記錄的「ANNOUNCE 把 Handle 連到暱稱」的曝光時間也跟著延長。成立中的回報在磁碟上（加密）保存到 Reporter 宣告安全或 panic 為止，不再是 2 小時。Reporter 宣告安全就停止。
- **Severity Inflation**：宣告輕傷就能換到持續重發。與 Relay Decision 一樣無法防止，只能量測。
- **位置會過時**：重發的是當時的位置；Reporter 移動後，Rescuer 要以 `reportTime` 判斷陳述與位置有多舊。
- **後台只看得到陳述，看不到重發**：Gateway 依 `reportTime` 判斷新舊與 2 小時期限（`MeshGateway`，以及 `mesh_reports` 規則要求 `reportTime` 不早於 130 分鐘前），所以重發不會重複上傳；但 2 小時內沒遇到 Gateway 的 SOS，之後的重發也上傳不了。要改，得同時改 Gateway 與 Firestore 規則，另議。
- **只在 `MeshForegroundService` 執行時重發**：使用者停止服務或強制結束 App，到下次啟動前都不會重發；啟動後依上一次發送的時間補發一次。
- **時鐘快超過 10 分鐘的手機**，它的 Health Report 仍會即時 flood 給範圍內的人，但不進任何同步暫存，晚到的 Rescuer 收不到。
- **debug 版的實驗發送器**送出的回報也會成為「最新一筆」：在真實 SOS 之後跑實驗，該 SOS 就不再重發，直到 Reporter 再送一次。
- **驗證**：E5-D 的延伸。Rescuer 在 SOS 送出 2 小時以上才入網，連上後應收到這份回報（經同步或下一次重發），`reportTime` 仍是原始時間，Health 畫面只有一筆。
