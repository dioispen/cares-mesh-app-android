# CARES Mesh（Android）

> [!WARNING]
> 本軟體未經外部安全審查，可能存在漏洞，也未必達成其宣稱的安全目標。請勿用於敏感情境，在完成審查前請勿依賴其安全性。本專案為在校專題，開發中。

一套離線的災害應變 mesh 應用。受災者在無任何基礎設施的情況下，透過 Bluetooth LE mesh 發布自身狀況與位置；救援者讀取這些回報，據以決定優先前往的對象。

本專案是 [bitchat-android](https://github.com/permissionlesstech/bitchat-android) 的**修改版 fork**，保留其 BLE mesh 傳輸層與二進位協定，在其上加入災害應變的應用層。**詳細的來源說明與 GPLv3 授權義務見 [NOTICE.md](NOTICE.md)。**

領域語彙以 [CONTEXT.md](CONTEXT.md) 為準（Health Report、Status、Severity 等詞在本專案有精確定義，不可混用）。

---

## 本組的修改

上游 bitchat 是一套通用的匿名通訊軟體。本專案將其改造為災害應變工具，主要改動如下：

### 應用層（新增）

| 項目 | 位置 |
|---|---|
| **Health Report 封包** — 受災者自述狀況（Status）、位置與聯絡資訊的線路格式與序列化 | `app/.../protocol/DisasterReportPacket.kt` |
| **Flutter ↔ Android 橋接** — MethodChannel／EventChannel，讓 Flutter UI 驅動原生 mesh | `app/.../flutter/BitchatFlutterChannels.kt`、`FlutterChatActivity.kt` |
| **網際網路上行** — 在有網路時將封包轉送至雲端 | `app/.../net/PacketUplinkManager.kt` |
| **Flutter UI 全套畫面** — 登入／註冊／信箱驗證、首頁、SOS、避難所地圖、物資、防災知識、健康回報 | `flutter_ui/lib/screens/` |
| **Firebase 整合** — 使用者驗證與健康資料儲存 | `flutter_ui/lib/services/auth_service.dart` |

### 上游元件的修改

- `mesh/MessageHandler.kt` — 加入 tagged broadcast 處理路徑（`BroadcastContentTag`）
- `mesh/BluetoothMeshService.kt`、`mesh/PacketProcessor.kt` — 接上災害回報流程
- `protocol/BinaryProtocol.kt` — 新增 `HEALTH_REPORT`（`0x30`）等訊息型別
- `service/MeshForegroundService.kt`、`service/MeshServiceHolder.kt` — 前景服務生命週期調整
- `ui/`、`MainActivity.kt` — 移除或停用不適用於本情境的上游 UI
- Gradle — 嵌入 `:flutter` 子專案、加入 google-services plugin

完整的檔案層級差異：`git diff 632ee88 main`（`632ee88` 為 fork 自上游的最後一個未修改狀態）。

---

## 建置

### 前置需求

- Android Studio（含 Android SDK，compileSdk 36、minSdk 26）
- JDK 17 以上
- Flutter SDK（Dart SDK `^3.11.1`）— `flutter_ui/` 以 Gradle 子專案形式嵌入，建置 Android 前必須先取得 Flutter 相依套件

### 步驟

```bash
git clone https://github.com/dioispen/cares-mesh-app-android.git
cd cares-mesh-app-android

# 1. 取得 Flutter 相依套件（缺這一步 Gradle 會失敗）
cd flutter_ui && flutter pub get && cd ..

# 2. 建置
./gradlew assembleDebug        # per-ABI + universal APK
./gradlew installDebug         # 安裝到已連接的裝置

# 測試
./gradlew test                 # Kotlin 單元測試
cd flutter_ui && flutter test  # Dart 測試
```

`assembleDebug` / `assembleRelease` 會產生分 ABI 的 APK（arm64、x86_64、armeabi-v7a、x86）加上一個 universal APK；`bundleRelease` 會關閉 split（由 Play Store 處理 ABI 分發）。

### Firebase

需要 `app/google-services.json`。本 repo 未納入該檔，向組內索取。

---

## 架構

Android（Kotlin）層擁有全部的網路、密碼學與背景服務；Flutter 層擁有絕大多數使用者可見的畫面。

```
flutter_ui/lib/screens/          使用者畫面
        │
        ├── bridge/bitchat_bridge.dart      Dart 端唯一的原生呼叫入口
        │        ▲  MethodChannel（動作）／EventChannel（事件）
        │        ▼
app/.../flutter/BitchatFlutterChannels.kt   Kotlin 端橋接
        │
        ├── mesh/BluetoothMeshService        BLE mesh 核心
        ├── protocol/BinaryProtocol          線路格式
        ├── noise/、crypto/                  Noise 握手與加密
        └── service/MeshForegroundService    背景常駐
```

### 主要套件

| 套件 | 職責 |
|---|---|
| `mesh/` | BLE mesh 核心 — `BluetoothMeshService` 協調 `PeerManager`、`FragmentManager`、`SecurityManager`、`StoreForwardManager`、`MessageHandler`、`BluetoothConnectionManager`、`PacketProcessor` |
| `protocol/` | 線路格式 — `BinaryProtocol.kt` 編解碼；`MessageType`、`BroadcastContentTag` 定義封包型別；`HealthReportPayload` 為健康回報結構 |
| `service/` | 前景服務 — `MeshForegroundService` 維持 mesh 存活；`MeshServiceHolder` 為單例存取點 |
| `crypto/`、`noise/` | X25519／Ed25519／AES-256-GCM（BouncyCastle）與 Noise Protocol 會話 |
| `net/` | 網際網路上行與 Tor／Arti |
| `flutter/` | Flutter 橋接 |
| `ui/` | Jetpack Compose 舊版 UI（多數畫面已由 Flutter 取代） |

更完整的說明見 [AGENTS.md](AGENTS.md)。

---

## 協定要點

- 封包標頭：version(1) + type(1) + TTL(1) + timestamp(8) + flags(1) + payloadLength(2 或 4)
- 最大 TTL 為 7 跳
- 訊息 >100 bytes 自動以 LZ4 壓縮
- 與上游 iOS bitchat 的二進位協定相容性由上游維持；本組新增的 `0x30` 等型別為本專案專有

**ContentTag 規則**：`MessageHandler.handleTaggedBroadcast()` 在轉交 Flutter 前已剝除 `payload[0]` 的 `BroadcastContentTag`。橋接層收到的是**未帶 tag 的原始 payload** — 不要在橋接層再次偵測或剝除 tag byte。

---

## 文件

| 文件 | 內容 |
|---|---|
| [CONTEXT.md](CONTEXT.md) | 領域語彙 — 專案用詞的權威定義 |
| [PLAN.md](PLAN.md) | 專題改善計畫、實驗矩陣、時程與分工 |
| [NOTICE.md](NOTICE.md) | fork 來源、GPLv3 義務、第三方元件 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 分支策略與 commit 規範 |
| [AGENTS.md](AGENTS.md) | 架構細節與開發標準 |
| [docs/adr/](docs/adr/) | 架構決策紀錄 |
| [PRIVACY_POLICY.md](PRIVACY_POLICY.md) | 隱私政策 |

---

## 分支現況

`main` 為專題的單一真相來源，所有工作分支都應由 `main` 開出。分支策略見 [CONTRIBUTING.md](CONTRIBUTING.md)。

**待處理**：`origin/penny` 有 2026-06-30 之後的 UI 修正（`login_screen`、`supply_screen`、`onboarding_screen`、`pubspec.lock`、iOS 平台設定檔等）尚未併入。這些改動與 `main` 上的同名檔案重疊，需要人工解衝突，不在 R1 的範圍內。

## 授權

本專案依 **GNU General Public License v3.0** 授權，與上游 bitchat-android 相同。完整條款見 [LICENSE.md](LICENSE.md)，來源說明與修改紀錄見 [NOTICE.md](NOTICE.md)。

> 上游 README 曾寫有「released into the public domain」，該敘述在上游於 2026-02-28 將授權由 MIT 改為 GPLv3（commit `fb2bb64`）後即已失效。本 repo 的授權以 `LICENSE.md` 為準。
