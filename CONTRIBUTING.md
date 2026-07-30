# 開發規範

本檔案定義本專題的分支策略與 commit 規範（[PLAN.md](PLAN.md) 的 R9）。
架構細節與程式碼風格見 [AGENTS.md](AGENTS.md)；領域用詞見 [CONTEXT.md](CONTEXT.md)。

---

## 分支策略

### `main` 是唯一的整合分支

`main` 永遠是可建置、可展示的狀態。所有工作分支都從 `main` 開出，也都併回 `main`。

**不要**從其他人的工作分支開新分支 — 這是本專案先前分支結構混亂的成因（`penny` → `using-flutterchatactivity` → `disaster_packet_and_comm` 的鏈狀關係讓任何一段的合併都變成解衝突作業）。

```bash
git checkout main
git pull
git checkout -b feat/severity-relay-policy
```

### 分支命名

`<type>/<簡短描述>`，描述用小寫英文與連字號：

| 前綴 | 用途 |
|---|---|
| `feat/` | 新功能 |
| `fix/` | 修 bug |
| `exp/` | 實驗程式碼、模擬器情境 |
| `docs/` | 只動文件 |
| `chore/` | 建置設定、相依套件、雜項 |

例：`feat/broadcast-tier`、`fix/health-report-content-tag`、`exp/simulator-baseline`。

以個人名字命名分支（`penny`、`amy`）已停用 — 分支名要能看出裡面是什麼，不是誰寫的。

### 併回 `main`

一律開 Pull Request，不直接 push 到 `main`。

1. 從 `main` 開分支、完成工作
2. 推上 `origin`，開 PR 到 `main`
3. 請一位組員 review 後合併
4. 合併後刪除該分支（GitHub 上與本地都刪）

`main` 已設定 branch protection：**強制走 PR、禁止 force push、禁止刪除分支、PR 上的 review comment 須全部解決才能合併**。approve 數量不強制（避免 7 人隊伍卡在時間喬不攏），但「請人 review」是團隊約定，不是可選項。

repo admin 在緊急情況下可 bypass 保護規則 — 這是逃生口，不是日常流程。

分支存活時間越短越好。一個分支活超過兩週，就該考慮它是不是該拆小。

### 保持與 `main` 同步

工作期間定期 `git pull --rebase origin main`，不要讓分支落後 `main` 幾十個 commit 才想合併。

---

## Commit 規範

### 格式

```
<type>: <繁體中文的簡短描述>

<繁體中文的說明，解釋「為什麼」，不是重述「做了什麼」>
```

### type 前綴

| type | 用途 |
|---|---|
| `feat` | 新功能 |
| `fix` | 修 bug |
| `docs` | 文件 |
| `test` | 測試 |
| `refactor` | 重構，不改行為 |
| `perf` | 效能改善 |
| `chore` | 建置、相依套件、設定 |

### 語言

- Title 與 description **一律使用繁體中文**。
- 例外一：[CONTEXT.md](CONTEXT.md) 定義的領域語彙（Health Report、Status、Reporter、Broadcast Tier、Detail Tier、Severity、Severity Inflation、Relay Decision）**維持原文**，不翻譯、不改寫，以免與 CONTEXT.md 的 _Avoid_ 清單衝突。
- 例外二：技術識別字（類別名、檔名、指令、type prefix）保留原文。

### 寫法

**要**：說明改動的動機與取捨。日後被追問「這裡為什麼這樣寫」時，答案應該在 commit message 裡。

```
fix: 移除健康回報封包重複剝除 ContentTag 的邏輯

MessageHandler.handleTaggedBroadcast() 在轉交前已剝除 payload[0]，
橋接層再剝一次會吃掉第一個 byte 的真實資料。
```

**不要**：無資訊量的標題。以下都是本 repo 歷史上實際出現過、應避免的例子：

```
Add files via upload
fix bug(detail below)
hhhdart
部分效能修復
```

### 顆粒度

一個 commit 做一件事。「順手改的」東西另外開一個 commit — 混在一起的 commit 沒辦法單獨 revert，也沒辦法在 review 時單獨討論。

---

## 送出 PR 前

```bash
./gradlew test                 # Kotlin 單元測試
cd flutter_ui && flutter test  # Dart 測試
./gradlew lint                 # Lint
```

改到協定或封包格式時，`app/src/test/kotlin/com/bitchat/android/protocol/` 下的測試必須通過。這些測試是三端封包格式的權威（見 PLAN.md 的 R6）。

---

## AI agent 協作

由 AI agent 產生的 commit 在 message 結尾加上：

```
Co-Authored-By: <model name> <noreply@anthropic.com>
```

agent 同樣受本檔案的所有規範拘束。
