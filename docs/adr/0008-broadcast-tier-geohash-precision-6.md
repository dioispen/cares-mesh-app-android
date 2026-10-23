# Broadcast Tier 的 geohash 精度由 5 提高為 6

ADR-0003 把 Health Report 的位置降為 geohash 精度 5 才廣播，理由是「足以做檢傷排序，不足以定位到 Reporter 本人」。Gateway（見 [MESH_GATEWAY.md](../MESH_GATEWAY.md)）把 Broadcast Tier 代傳到 Firestore 之後，管理後台要以**村里、收容避難所的層級**統計各區有多少人需要協助；精度 5 在台灣緯度約為 4.9 × 4.5 km，一格涵蓋整個鄉鎮區的一部分，對不上村里。

我們把 Broadcast Tier 的 geohash 精度改為 **6**（台灣緯度約 0.6 × 1.1 km，約 0.68 km²，與台北市一個里的平均面積相當；鄉間的村通常更大）。解碼端**只接受長度 0 或 6**，不再接受 5；payload 版本不變。

## Considered Options

- **維持精度 5，另以加密 Detail Tier 上傳精確座標給後台**：見 ADR-0009。需要伺服器端解密，專案目前不開 Blaze 方案，私鑰只能放在管理員的瀏覽器裡。
- **精度 7（約 150 × 140 m，幾棟建築）**：能對應到單一收容所的服務範圍，但放棄 ADR-0003「不足以定位本人」的立場；加上 ADR-0006 記錄的「ANNOUNCE 把 Handle 連到 mesh 暱稱」，範圍內的人幾乎可以指認是誰。
- **解碼端同時接受 5 與 6**：可以和舊版裝置並存一段時間，但原型階段所有裝置會一起更新，兩種精度並存只會讓後台與 App 內的 BLE 互助任務都得處理兩種格子。
- **升 payload 版本**：`geohashLen` 欄位本身已說明精度，升版本不承載額外資訊；舊版裝置無論如何都會拒收。

## Consequences

- **舊版裝置與新版互相拒收所有 Health Report**，不只是帶位置的那些（`geohashLen` 為 0 的回報除外）。與 ADR-0004 升 v2 一樣，實機實驗期間不能混用版本；切換時所有裝置一起更新。
- **Broadcast Tier 上界由 19 增為 20 bytes**（`DisasterReportPacket.MAX_ENCODED_SIZE`）。對 ADR-0003 F3（~150 B 對 ~18 B）的結論沒有影響。
- **隱私立場大致不變但變弱**：精度 6 在都市一格仍有數千人，單看 Broadcast Tier 仍不足以定位本人；但配合 mesh 暱稱與持久的 peerID，可推測的範圍從數公里縮到約一公里。`DisasterReportPacket.kt` 對 geohash-5 的說明要一併改寫。
- **App 內的 BLE 互助任務也跟著變準**：geohash 還原的概略中心從數公里縮到約一公里。`Geohash.decodeToCenter` 對任意長度通用，不需修改。
- **Kotlin（`DisasterReportPacket.GEOHASH_PRECISION`）與 Dart（`HealthReportPayload.geohashPrecision`）必須同時改**，並更新兩端共用的權威向量（`DisasterReportTest`、`health_report_payload_test.dart`）。
