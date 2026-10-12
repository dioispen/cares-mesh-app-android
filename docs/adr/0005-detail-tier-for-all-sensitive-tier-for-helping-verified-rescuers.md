# 後端的 Health Report 分成 Detail Tier 與 Sensitive Tier

ADR-0003 把 Health Report 分成 Broadcast Tier 與 Detail Tier，後端則由 issue #33 把 `health_reports` 整份收斂為「只有 Reporter 本人與救援者可讀」。但互助任務的前提是一般使用者也能看到附近誰需要幫忙、在哪裡，#33 的規則讓非救援者一進互助任務頁就讀取失敗。經團隊討論，後端改成兩份文件：

- **Detail Tier**（`health_reports/{uid}`）：姓名、居住區域、Status 與傷勢細項、**精確座標**、回報時間，以及互助任務的 `taskStatus`／`helperId`。**任何登入帳號都能讀**。
- **Sensitive Tier**（`health_report_sensitive/{uid}`）：電話、血型、病史、緊急聯絡人。只有 Reporter 本人，以及**此刻正擔任這筆 Mutual-aid Task 之 Helper 的 Verified Rescuer** 讀得到；放棄或完成任務後就讀不到。只解鎖自己接的那幾筆。

Verified Rescuer 沿用 #33 的 `rescuers/{uid}` 名單，只能由後台授予。任何人都能接任務成為 Helper，認證只是讀 Sensitive Tier 的必要條件。BLE 的 Broadcast Tier 不變。

## Considered Options

- **維持 #33（整份只給本人與救援者）**：一般使用者看不到互助任務，「survivors 互救」這個核心情境做不到。
- **整份對所有登入帳號開放**（#33 之前的狀態）：註冊是開放的，等於把電話、血型、病史交給任何註冊的人。
- **同一份文件做欄位層級讀取限制**：Firestore 規則只能決定整份文件可不可讀，做不到；只能拆成兩份文件。
- **Verified Rescuer 讀得到所有人的 Sensitive Tier**（#33 的做法）：揭露範圍遠大於實際需要。只給正在協助的那一筆，名單上的帳號外流時影響也較小。
- **精確座標放進 Sensitive Tier、Detail Tier 只放概略位置**：接任務前就無法導航過去（#63），而現場的人多半不是 Verified Rescuer。團隊決定精確座標公開。

## Consequences

- **姓名與精確座標對任何登入帳號公開，而註冊是開放的。** 任何人註冊後都能知道誰在哪裡受傷——這是為了讓附近的人能趕過去而刻意接受的取捨，隱私政策需寫明。
- **#33 對 `health_reports` 的讀取限制被取代**，`rescuers` 名單的意義從「整批讀取全部回報」變成「讀 Sensitive Tier 的必要條件」。
- **規則擋得了之後的讀取，收不回已讀到的內容**：Helper 放棄或完成任務後，先前讀到手機上的電話等資料仍在對方裝置上。
- **Detail Tier 文件用 `keys().hasOnly()` 鎖住欄位**，避免日後有人把敏感欄位加回這份大家都讀得到的文件。現有的舊文件都含有 `phone`／`bloodType`：#60 之前以 `add()` 寫的隨機 ID 文件，在新規則下會對所有登入帳號公開；#60 版本寫的 `{uid}` 文件除此之外，還會讓 Reporter 再回報時被規則擋下。這些舊資料**不遷移，部署新規則前要從後台清掉整個 `health_reports`**。
- **病史與緊急聯絡人新加進 Health Report**（取自個人檔案，放在 Sensitive Tier）。#83 原本列為「另開 issue 討論」的病史，依此決定處理；#83 把 SOS 搬進 `health_reports` 時，也要沿用這兩份文件的分法。
- **ADR-0003 的 A2**（Detail Tier 經 Noise session 逐一釋出）仍未實作；日後若實作，mesh 上釋出的範圍應比照本 ADR 的分級，而不是 ADR-0003 原本的 Detail Tier 定義。
- `sos_requests` 的讀取範圍（#64）不在本次處理，留給 #83。
