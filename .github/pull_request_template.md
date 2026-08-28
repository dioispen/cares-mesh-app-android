<!--
  分支與 commit 規範見 CONTRIBUTING.md，架構見 AGENTS.md，領域用詞見 CONTEXT.md。
  reviewer 不一定熟悉你負責的模組 — 下面三段的目的，是讓他不用讀懂全部也能給出有用的意見。
-->

## 改了什麼

<!-- 一到三句話說明動機與取捨，不是重述 diff。日後被追問「為什麼這樣寫」，答案應該在這裡。 -->

Closes #

## reviewer 該看哪裡

<!--
  指出最需要被看的檔案與行數，例如：
  - BinaryProtocol.kt:120-135 — 新增 severity 欄位的編碼順序
  - bitchat_bridge.dart:88 — 對應的 Dart 側解析
  其餘部分屬於樣板或連帶修改，可略過。
-->

## 我怎麼驗的

<!-- 真機 / 模擬器 / 單元測試？測了哪些情境？有哪些沒測到？ -->

---

## 檢查清單

- [ ] 已讀過 [CONTRIBUTING.md](https://github.com/dioispen/cares-mesh-app-android/blob/main/CONTRIBUTING.md)，分支名與 commit 訊息符合規範（commit 使用繁體中文）
- [ ] 已自我 review 過一次 diff，沒有留下除錯用的 log 或註解掉的程式碼
- [ ] 分支已與 `main` 同步（`git pull --rebase origin main`）
- [ ] 本機檢查通過：
  ```bash
  ./gradlew test                 # Kotlin 單元測試
  cd flutter_ui && flutter test  # Dart 測試
  ./gradlew lint                 # Lint
  ```

## 影響範圍

- [ ] **只動我負責的功能目錄** — 任一位組員看過 PR 描述、CI 綠燈即可合併
- [ ] **動到共用介面** — `protocol/`、`mesh/`、`BitchatFlutterChannels.kt`、`bridge/bitchat_bridge.dart`、`MessageType` / `BroadcastContentTag`
      → 必須指定該領域負責人 review，不由不相干的人放行。指定給： @

<!--
  提醒：Flutter 端收到的 tagged broadcast payload 已由 MessageHandler 剝除 payload[0]，
  橋接層不要再剝一次（見 CLAUDE.md 的 Payload ContentTag rule）。
-->
