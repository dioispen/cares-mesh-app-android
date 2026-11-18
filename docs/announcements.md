# 廣播訊息（管理中心 → 里民）

App 首頁右上角的小喇叭會打開「廣播訊息」，列出管理中心發過的所有公告。管理端目前用 **Firebase 主控台** 發送；App 只能讀，不能發。

## 怎麼發一則廣播

1. 打開 [Firebase 主控台](https://console.firebase.google.com/) → 專案 **disaster-app**（`disaster-app-b2370`）→ Firestore Database
2. 選集合 `announcements`（第一次發送時按「開始集合」建立，集合 ID 填 `announcements`）
3. 按「新增文件」，文件 ID 用「自動產生 ID」，依下表填欄位後儲存

儲存後，已開著 App 的使用者會即時看到，小喇叭上也會出現未讀數。

| 欄位 | 類型 | 必填 | 說明 |
|---|---|---|---|
| `body` | string | ✅ | 訊息內容 |
| `createdAt` | timestamp | ✅ | 發送時間，決定排列順序與「今天／昨天」的分組 |
| `audience` | string | ✅ | `all`：發給所有使用者；`user`：只發給一位使用者 |
| `targetUid` | string | `audience` 為 `user` 時必填 | 收件人的 User ID（使用者在 App 的個人資料面板可以看到、複製） |
| `title` | string | | 標題，以粗體顯示在內容上方 |
| `level` | string | | `info`（一般，預設）、`important`（重要，橘色）、`urgent`（緊急，紅色） |

缺少 `body` 或 `createdAt` 的文件不會顯示，可以當作草稿先存。

### 範例

發給全體：

```
body:      "今晚 20:00 起至明早 06:00 全里停水，請預先儲水。"
title:     "停水通知"
audience:  "all"
level:     "important"
createdAt: 2026-10-22 18:00
```

只發給一位使用者：

```
body:      "您申請的輪椅已送達活動中心，請攜帶身分證領取。"
audience:  "user"
targetUid: "<該使用者的 User ID>"
createdAt: 2026-10-22 18:30
```

## 誰看得到

由 `firestore.rules` 的 `match /announcements/{docId}` 控制：

- `audience` 為 `all`：所有已登入的使用者
- `audience` 為 `user`：只有 `targetUid` 本人；其他人讀不到，也查不到
- App 端一律不可新增、修改或刪除；只有主控台或 Admin SDK 能寫入，避免有人冒充管理中心

廣播永久保留在 App 的紀錄裡。要撤回某則廣播，在主控台刪除那份文件即可，App 會即時移除。

## 之後做管理工具

若要做管理網頁，沿用同一個集合與欄位即可，App 不需要改。寫入要走 Admin SDK（或另外在規則中開放給管理者帳號），因為規則對所有客戶端都是 `allow write: if false`。
