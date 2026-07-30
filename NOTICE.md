# NOTICE

本檔案說明本專案的來源、授權義務與第三方元件，以滿足 GNU General Public License v3.0 第 4、5、6 條所要求的標示。

---

## 1. 這是一個修改版（GPLv3 §5(a)）

**本專案是 [bitchat-android](https://github.com/permissionlesstech/bitchat-android) 的修改版本，並非上游原始程式。**

| | |
|---|---|
| 上游專案 | `permissionlesstech/bitchat-android` |
| 上游授權 | GNU General Public License v3.0 |
| 本 fork | `dioispen/cares-mesh-app-android` |
| Fork 起點 | commit `632ee88`（2026-03-01，上游 `main` 的自動化 relay 資料更新） |
| 本組修改期間 | 2026-03-16 起，持續中 |
| 修改者 | 互 CARES 專題小組 |

上游程式碼的著作權屬於 bitchat-android 的各位貢獻者；本組僅對自身新增與修改的部分主張著作權。上游的原始著作權標示與授權聲明均已保留、未經移除。

上游 bitchat-android 本身是 [bitchat iOS](https://github.com/jackjackbits/bitchat) 的 Android 移植版。

### 授權沿革需注意

上游於 2026-02-28 以 commit `fb2bb64`（PR #674）將授權由 MIT 變更為 **GPLv3**。本 fork 的起點（2026-03-01）在該變更之後，因此本專案全體受 GPLv3 拘束。

上游 `README.md` 中「This project is released into the public domain」一句是該次變更後未同步更新的殘留敘述，**不代表本專案的授權狀態**。本 repo 的授權以 [`LICENSE.md`](LICENSE.md) 為準。

---

## 2. 修改摘要（GPLv3 §5(a) 要求的「修改內容與日期」）

自 2026-03-16 起，本組在上游程式碼上進行了以下修改。逐檔差異可以下列指令取得：

```bash
git diff 632ee88 main          # 全部修改
git log 632ee88..main          # 修改的逐筆紀錄與日期
```

### 新增的檔案

| 檔案 | 內容 |
|---|---|
| `app/src/main/java/com/bitchat/android/protocol/DisasterReportPacket.kt` | Health Report 封包結構與序列化 |
| `app/src/main/java/com/bitchat/android/flutter/BitchatFlutterChannels.kt` | Flutter ↔ Android MethodChannel／EventChannel 橋接 |
| `app/src/main/java/com/bitchat/android/flutter/FlutterChatActivity.kt` | 嵌入 Flutter 的 Activity |
| `app/src/main/java/com/bitchat/android/net/PacketUplinkManager.kt` | 封包的網際網路上行轉送 |
| `app/src/main/java/com/bitchat/android/service/MeshServiceHolder.kt` | mesh 服務單例存取點 |
| `app/src/test/kotlin/com/bitchat/android/protocol/DisasterReportTest.kt` | Health Report 封包測試 |
| `app/src/main/res/xml/network_security_config.xml`、`app/src/main/res/raw/server.crt` | 上行連線的網路安全設定 |
| `flutter_ui/`（整個目錄） | Flutter UI 模組 — 本組原創 |

### 修改的上游檔案

| 檔案 | 修改內容 |
|---|---|
| `mesh/MessageHandler.kt` | 新增 tagged broadcast 處理路徑（`BroadcastContentTag`） |
| `mesh/BluetoothMeshService.kt` | 接上災害回報流程、調整服務生命週期 |
| `mesh/PacketProcessor.kt` | 新增災害回報封包的分派 |
| `protocol/BinaryProtocol.kt` | 新增 `HEALTH_REPORT`（`0x30`）等訊息型別 |
| `service/MeshForegroundService.kt` | 前景服務生命週期調整 |
| `services/MessageRouter.kt` | 路由邏輯調整 |
| `net/OkHttpProvider.kt`、`net/ArtiTorManager.kt` | 上行連線與 Tor 設定調整 |
| `ui/MeshDelegateHandler.kt`、`ui/ChatHeader.kt`、`ui/ChatViewModel.kt`、`MainActivity.kt` | 移除或停用不適用於本情境的上游 UI |
| `ui/AboutSheet.kt` | 已刪除 |
| `BitchatApplication.kt` | 加入 Flutter engine 與 Firebase 初始化 |
| `AndroidManifest.xml` | 註冊 `FlutterChatActivity`、新增權限 |
| `build.gradle.kts`、`settings.gradle.kts`、`gradle/libs.versions.toml`、`app/build.gradle.kts` | 嵌入 `:flutter` 子專案、加入 google-services plugin、升級 AGP／Kotlin／compileSdk |
| `CHANGELOG.md` | 已刪除（記錄的是上游版本歷程，對本 fork 無意義） |

---

## 3. 取得對應原始碼（GPLv3 §6）

本專案的完整原始碼公開於：

<https://github.com/dioispen/cares-mesh-app-android>

若以 APK 等目的碼形式散布本軟體，散布者必須依 GPLv3 §6 一併提供對應的完整原始碼，或提供取得該原始碼的管道（指向上述網址即可滿足 §6(d)）。

**本組發布 release APK 時（見 [PLAN.md](PLAN.md) 的 R11），必須在 release note 中附上對應的 commit hash 或 tag。** 缺少這一項，該次散布即不符合 GPLv3。

---

## 4. 第三方元件

以下元件並非本專案所撰寫，各自依其原始授權條款散布。本清單為 GPLv3 §7(b) 的著作人標示，不取代各元件自身的授權檔案。

### 由上游 bitchat-android 引入（本組未修改）

| 元件 | 用途 |
|---|---|
| [BouncyCastle](https://www.bouncycastle.org/) | X25519、Ed25519、AES-256-GCM |
| [noise-java](https://github.com/rweather/noise-java)（southernstorm，已內嵌於 `app/src/main/java/com/southernstorm/`） | Noise Protocol Framework |
| [Nordic Android-BLE-Library](https://github.com/NordicSemiconductor/Android-BLE-Library) | Bluetooth LE 操作 |
| [Google Tink](https://github.com/tink-crypto/tink-java) | 密碼學工具 |
| [OkHttp](https://square.github.io/okhttp/) | HTTP／WebSocket |
| [Arti / tor-android](https://gitlab.torproject.org/tpo/core/arti)（`info.guardianproject:arti-mobile-ex`） | Tor 整合 |
| [ZXing](https://github.com/zxing/zxing)、[ML Kit Barcode](https://developers.google.com/ml-kit) | QR code |
| [Gson](https://github.com/google/gson) | JSON |
| AndroidX / Jetpack Compose / Kotlin Coroutines / CameraX / Play Services Location | Android 平台函式庫 |
| [Accompanist](https://github.com/google/accompanist) | 權限處理 |

上游程式碼中原有的著作權標頭與授權標示均已保留。各元件的實際版本見 [`gradle/libs.versions.toml`](gradle/libs.versions.toml)。

### 由本組引入

| 元件 | 用途 |
|---|---|
| [Flutter](https://flutter.dev/)（BSD-3-Clause） | UI 框架 |
| [Firebase Android SDK](https://firebase.google.com/) / `firebase_core`、`firebase_auth`、`cloud_firestore` | 使用者驗證與資料儲存 |
| `flutter_map`、`flutter_map_cache`、`dio_cache_interceptor_hive_store` | 離線地圖 |
| `geolocator`、`connectivity_plus`、`shared_preferences`、`path_provider`、`url_launcher` | 平台功能 |
| `video_player`、`flutter_inappwebview`、`flutter_tts`、`uuid`、`http`、`cupertino_icons` | UI 與工具 |

Dart 套件的完整清單與版本見 [`flutter_ui/pubspec.yaml`](flutter_ui/pubspec.yaml)。

### 素材

`flutter_ui/assets/` 下的吉祥物圖片、防災知識圖片與影片為本組自行製作或取得授權使用。**若其中有任何素材來自第三方，必須在此逐項補上來源與授權。**

---

## 5. GPLv3 合規檢查清單

發布任何形式的建置產物前，逐項確認：

- [x] `LICENSE.md` 保留 GPLv3 全文（§4）
- [x] 明確標示本專案為修改版，並註記修改日期（§5(a)）
- [x] 明確標示本專案依 GPLv3 授權（§5(b)）
- [x] 上游的著作權與授權標示未被移除（§4）
- [ ] 散布 APK 時提供對應原始碼的取得管道（§6）— **待 R11 release 時執行**
- [ ] App 內顯示授權資訊（§5(d)，Appropriate Legal Notices）— **待辦**，上游的 `AboutSheet.kt` 已於本 fork 刪除，需在 Flutter UI 中補回等效畫面

---

## 6. 已知的待處理事項

- `app/src/main/res/values/strings.xml` 的 `app_name` 目前為 `helloworld`，`settings.gradle.kts` 的 `rootProject.name` 仍為 `bitchat-android`，`applicationId` 仍為 `com.bitchat.droid`。GPLv3 §7(c) 允許上游要求修改版明確與原版區別；在對外散布前應改為本專案自己的名稱與 application ID，避免與上游 bitchat 混淆。
