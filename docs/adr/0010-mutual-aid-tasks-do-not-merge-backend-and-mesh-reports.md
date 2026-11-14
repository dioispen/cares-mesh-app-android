# 互救任務不合併後端與 mesh 上的同一位 Reporter

有網路的 Reporter 回報時，同一份 Health Report 會寫進 `health_reports/{uid}`，也會經 mesh 廣播 Broadcast Tier。Rescuer 同時有網路、又在 mesh 範圍內時，互救任務清單上會出現兩筆：一筆有名字與精確座標，一筆是「匿名回報」。我們決定兩筆都列出，不合併，也不標示可能是同一人。

兩邊沒有共同的鍵：後端以 uid 識別，mesh 以 Reporter Handle 識別，兩者的對照（`reporter_handles`）只有 Administrator 與本人讀得到（ADR-0009）。App 要可靠地合併，就得查得到 Handle 屬於誰；但註冊是開放的，Handle 在 mesh 上是明文，Rescuer 查得到，任何登入帳號也就查得到。

## Considered Options

- **Handle 寫進 Detail Tier，或開放對照表給所有登入帳號**：清單最乾淨。但聽到一個 Handle 就能查出姓名與精確座標，還能把之後的 mesh 回報串成行蹤，ADR-0009 已經否決。
- **改用 Handle 的雜湊或一次性 token 比對**：合併的人算得出來，旁聽的人也算得出來，等於上一項。
- **只開放對照表給 Verified Rescuer**：暴露面較小。但任何 Rescuer 都能當 Helper（ADR-0005），多數 Helper 沒有認證，仍會看到兩筆。
- **用 Status、SOS、geohash 與時間推測同一人，自動合併**：同一格 geohash（約 0.68 km²，ADR-0008）的兩個人在災後幾乎同時回報時，會被合成一筆，等於藏掉一個真實的求救。而且後端只留最新一份、補送位置會改內容，推測常常對不上，仍然會出現兩筆。
- **推測後只標示「可能是同一人」**：任務不會消失，但標錯時 Rescuer 可能跳過那筆匿名回報；也讓推測變得不費力。

## Consequences

- **兩位 Rescuer 可能分別接下同一人的兩筆，多跑一趟。** 這只在 Rescuer 有網路、又在 mesh 範圍內聽到已上傳的 Reporter 時發生；完全斷網時根本沒有後端那筆。多跑一趟的代價小於漏掉一個人。目前沒有數據知道多常發生；實地測試若發現很常見，再評估標示，或重新討論 ADR-0009。
- **兩筆的進度各自獨立。** BLE 那筆的進度只記在接下它的人手機上，接了它不會讓後端那筆變成進行中，反之亦然。
- **Reporter Handle 並非完全無法連結。** 任何同時看得到兩邊的人，都能用 Status、SOS、geohash 與時間手動推測；ADR-0006 也記錄了 ANNOUNCE 讓 Handle 連到 mesh 暱稱。這個決定只是不讓 App 替人做這件事，也不提供可靠的對照。
