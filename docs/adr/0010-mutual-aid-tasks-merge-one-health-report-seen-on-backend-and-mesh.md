# 互助任務合併後端與 mesh 上的同一份 Health Report

有網路的 Reporter 回報時，同一份 Health Report 會寫進 `health_reports/{uid}`，也會經 mesh 廣播 Broadcast Tier。Rescuer 如果同時有網路、又在 mesh 範圍內，互助任務清單上就會出現兩筆：一筆有名字，另一筆是「匿名回報」。過去兩邊沒有共同的鍵：後端以 uid 識別，mesh 以 Reporter Handle 識別，兩者的對照（`reporter_handles`）只有 Administrator 與本人讀得到（ADR-0009）。App 要合併就得查得到 Handle 屬於誰，所以當時決定兩筆都列出。

Broadcast Tier 改帶精確座標之後（ADR-0008），兩邊帶的是同一組精確座標與 `reportTime`。任何同時看得到兩邊的人都對得起來，App 不合併已經保護不了什麼，只剩下兩位 Rescuer 分別接下同一個人、多跑一趟的代價。我們改為**合併同一份 Health Report**：

- 後端的一筆與 mesh 的一筆，**精確座標、`reportTime`、Status 與 SOS 全部相同**時，就是同一份 Health Report，清單上只列一筆。座標以線路的解析度（1e-7 度）比較；`reportTime` 比到秒，因為 mesh 只帶到秒。
- 合併後的那筆顯示後端的內容（姓名、傷勢細項、狀況調查），進度跟著後端那筆的 `taskStatus`／`helperId`，其他 Rescuer 才看得到已經有人接了。
- 四項中只要有一項不同，就是不同的 Health Report，照舊兩筆都列出。
- 不記住 Handle 屬於哪個帳號，每次只比對清單上當下的兩筆。

## Considered Options

- **維持不合併**（本 ADR 原本的決定）：當時的理由是兩邊沒有共同的鍵，App 不該替人連結 Handle 與帳號。精確座標讓任何人都對得起來之後，不合併只剩多跑一趟的代價。
- **只比對座標與 `reportTime`**：座標與時間相同、Status 或 SOS 卻不同，代表其中一份不是 Reporter 本人送的，例如有人拿後端讀到的座標與時間偽造一份 mesh 回報。這時合併，等於 App 替使用者挑了一份相信。四項全部比對，併掉的副本內容就和真的一模一樣。
- **記住配對，之後這個 Handle 的回報都併到同一個帳號**：兩邊不同步時也能合併，例如 Reporter 上傳之後只剩 mesh 可以更新。但這樣每台裝置都會累積一份 Handle↔帳號的對照表，也就是 ADR-0009 只給管理員的那一份；而且同一支手機登入過兩個帳號時，Handle 會被併到錯的人身上。
- **Handle 寫進 Detail Tier，或開放對照表給所有登入帳號**：清單最乾淨，但任何人不必在 mesh 範圍內，就能用任何 Handle 查出姓名，ADR-0009 已經否決。
- **只標示「可能是同一人」，不合併**：精確比對沒有不確定的情況，標示只是多一個步驟。

## Consequences

- **兩邊不同步時仍然是兩筆。** 後端每個帳號只留最新一份。Reporter 上傳之後如果只能經 mesh 更新（斷網；Gateway 只寫 `mesh_reports`，不寫 `health_reports`），兩邊就是不同的 Health Report，清單上維持兩筆，直到後端也更新為止。Rescuer 要用 `reportTime` 判斷哪一筆比較新。這時兩位 Rescuer 仍可能分別接下同一個人，多跑一趟。
- **App 替使用者連結了 Handle 與姓名。** 合併後的那一筆同時帶著 mesh 的 Handle 與後端的姓名。這本來就算得出來（ADR-0008），App 只是不再假裝算不出來。
- **合併前在本機接下 BLE 那一筆的 Rescuer**，合併後看到的是後端那一筆的進度。後端還在等待時，要在後端再接一次，其他 Rescuer 才看得到。BLE 那一筆原本的進度只記在本機，合併後不再使用。
- **只有同時有網路、又在 mesh 範圍內的 Rescuer 會遇到合併**；完全斷網時根本沒有後端那一筆。
