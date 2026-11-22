# Broadcast Tier 帶精確座標，與 Detail Tier 共用同一份位置

ADR-0003 原本把 Health Report 的位置降成 geohash 精度 5 再廣播，理由是「足以做檢傷排序，不足以定位到 Reporter 本人」。後來為了讓管理後台能以村里統計，精度提高到 6（台灣緯度約 0.6 × 1.1 km）。但這樣降精度，真正吃虧的是需要位置去找人的人：

- **斷網時，Rescuer 手上只有 mesh 那一筆。** mesh 本來就是為這種情境存在的。一格約 0.68 km² 的格子中心導航不到本人，而最需要救援的 Reporter 往往已經無法操作手機回應。後端的 Detail Tier 早已對所有登入帳號公開精確座標（ADR-0005；#63：接任務前要能導航過去），結果 mesh 反而比後端更不準。
- **管理後台要能派人到個別的 Reporter**，不只是統計各村里有多少人。Gateway 代傳的是 Broadcast Tier（ADR-0009），精度 6 只夠統計。

我們讓 **Broadcast Tier 帶精確座標**，與 Detail Tier（`health_reports/{uid}` 的 `lat`／`lng`）共用同一份位置：Reporter 送出時，後端與 mesh 拿到的是同一組座標。姓名、居住區域、傷勢細項與狀況調查仍然只放後端（ADR-0005、ADR-0007）。

線路格式：

- payload 版本升為 **3**。
- 位置是兩個 big-endian int32：緯度、經度，單位 1e-7 度（約 1.1 cm，比任何手機 GPS 都細，等於不降精度）。取代原本的 `geohashLen`＋ASCII geohash。
- flags 的 **bit1** 表示有沒有帶位置；沒有位置時不帶這 8 bytes。
- 解碼端**只接受版本 3**，版本 1、2（geohash）一律拒收。

## Considered Options

- **維持 geohash-6**（本 ADR 原本的決定）：它保護的是「範圍內的人不知道 Reporter 在哪一棟」，代價卻落在斷網時唯一的那一筆回報上。而且同一個人的精確座標，任何註冊帳號在後端本來就讀得到。
- **geohash-7（約 150 × 140 m）**：仍然要在幾棟建築之間找人，對困在室內、無法回應的 Reporter 不夠。
- **只有帶 SOS 的回報才帶精確座標**：輕傷、重傷一樣是 Mutual-aid Task，也一樣需要有人找得到。而且兩種精度並存，互助任務、Gateway 與後台都得各處理兩套。
- **精確座標經 Noise session 逐一釋出給提出請求的 Rescuer**（ADR-0003 原本的 A2）：前提是 Reporter 的手機在線、在範圍內，而且能回應請求。經同步補送收到回報時，Reporter 往往早就不在範圍內，而最需要救援的人最可能無法操作手機。A2 也一直沒有實作。
- **用後台公鑰加密精確座標**：只有管理後台解得開，離線的 Rescuer 仍然只有概略位置；伺服器端解密的問題見 ADR-0009。
- **把 geohash 提高到 9 以上（ASCII）**：9 個字元約 4.8 × 4.8 m，卻比兩個 int32 多 1 byte，還多一道編解碼。int32 可以和 Firestore 的 `lat`／`lng` 直接對應。

## Consequences

- **藍牙範圍內任何人都知道 Reporter 確切在哪，不需要帳號。** 過去至少要註冊才讀得到精確座標，現在聽得到 mesh 就夠了。再加上 ADR-0006 記錄的「ANNOUNCE 把 Handle 連到 mesh 暱稱」，旁人能知道「某個暱稱的人重傷，就在這裡」。舉著 SOS 或受傷的回報每 30 分鐘重發一次（ADR-0012），所以 Reporter 宣告安全之前，這個位置會一直被廣播；同步暫存又讓它在整個連通的網路裡留 2 小時，不受 TTL 限制。這是為了讓人找得到而刻意接受的取捨，隱私政策要寫明。
- **Reporter Handle 不再無法連結到姓名。** 後端與 mesh 帶的是同一組精確座標與 `reportTime`，任何登入帳號只要兩邊都看得到，就能把 Handle 對到 Detail Tier 上的姓名。Handle 跨回報不變，所以之後這個 Handle 在 mesh 上的回報也連得到這個人。ADR-0009「Handle 與 uid 的對應只給管理員」因此不再是保證；ADR-0010 改為依此合併互助任務。
- **Broadcast Tier 上界由 20 增為 21 bytes**（沒有位置時由 14 減為 13，`DisasterReportPacket.MAX_ENCODED_SIZE`）。對 ADR-0003 F3（~150 B 對 ~18 B）的結論沒有影響。
- **新舊版裝置互相拒收所有 Health Report**，沒帶位置的也一樣，因為版本號不同。與 ADR-0004 升 v2 一樣，實機實驗期間不能混用版本，切換時所有裝置要一起更新。
- **App 內的 BLE 互助任務改用精確座標**：顯示、距離與導航都和後端那一筆一樣。Health Report 不再需要 `Geohash.decodeToCenter`。
- **Gateway 代傳精確座標**：`mesh_reports` 的 `geohash` 欄位改成 `lat`／`lng`，Firestore 規則與 `docs/MESH_GATEWAY.md` 要一起改。這份資料仍然只有 Administrator 讀得到。
- **Kotlin（`DisasterReportPacket`）與 Dart（`HealthReportPayload`）必須同時改**，並更新兩端共用的權威向量（`DisasterReportTest`、`health_report_payload_test.dart`）。
