# 筆電與 adb 常用指令

實驗時在筆電上會用到的指令。完整的操作順序（什麼時候清 log、什麼時候拉 log）見 [field-day-runbook.md](field-day-runbook.md)，這份只是查指令用。

## 筆電環境（第一次設定）

### 用 Git Bash，不要用 PowerShell 或 WSL

runbook 與這份文件的指令都是 bash 語法，要在 **Git Bash** 執行：

- PowerShell 不支援 `$(...)`、`for ... do`、`mkdir -p`，指令會直接報錯。
- WSL 預設看不到 USB 接的手機（要另裝 usbipd-win，而且每次插線都要重新 attach），WSL 裡的 adb 也會和 Windows 的 adb 搶裝置。

在 VS Code 裡開 Git Bash：終端機面板右上角 `+` 旁的 `∨` → 選「Git Bash」。想設成預設，按 `Ctrl+Shift+P` → `Terminal: Select Default Profile` → Git Bash。

### 把 adb 加進 PATH

Android Studio 會把 adb 裝在 `%LOCALAPPDATA%\Android\Sdk\platform-tools`，但不會加進 PATH。

1. Win 鍵搜尋「編輯您帳戶的環境變數」並打開。
2. 「使用者變數」選 `Path` → 編輯 → 新增，貼上（`<使用者>` 換成自己的 Windows 帳號名稱）：
   ```
   C:\Users\<使用者>\AppData\Local\Android\Sdk\platform-tools
   ```
3. 一路按確定，然後**把 Git Bash 或整個 VS Code 關掉重開**（已經開著的終端機讀不到新的 PATH）。

確認：

```bash
adb devices
```

列出手機序號、狀態是 `device` 就設好了。

### 手機端

設定 → 關於手機 → 連按「版本號碼」7 次開啟開發人員選項 → 開發人員選項裡打開「USB 偵錯」。第一次接筆電時，手機會跳出「允許 USB 偵錯嗎？」，勾「一律允許」再按允許。

## 裝置

```bash
# 列出接著的手機（第一欄是序號，下面的 -s 用它）
adb devices

# 接了好幾支時，每個指令都要用 -s 指定是哪一支
adb -s 10AD5Q1M4R001H5 shell getprop ro.product.model

# 嫌每次打序號麻煩，先存成變數（runbook 的 $S 就是這個）
S=10AD5Q1M4R001H5
adb -s "$S" shell getprop ro.product.model
```

只接一支手機時可以省略 `-s`。下面的範例都省略，接多支時記得自己補上。

## 即時看 log

```bash
# 只看實驗事件（TX、RX、DUP、STAT、LINK_*、RSSI 等），Ctrl+C 停止
adb logcat -s CARES_EXP

# 只看 Health Report（0x30）的收送
adb logcat -s CARES_EXP | grep --line-buffered ',0x30,'

# 只看收到的 Health Report（第一次收到與重複）
adb logcat -s CARES_EXP | grep --line-buffered -E ',(RX|DUP),0x30,'

# 邊看邊存一份到檔案
adb logcat -s CARES_EXP | tee live.txt

# 看整個 app 的 log（app 要先開著），查閃退或錯誤時用
adb logcat --pid=$(adb shell pidof com.bitchat.droid)
```

每一行 `CARES_EXP:` 後面就是 `exp.csv` 的一列，欄位依序是 `t_ms,ev,type,src,pts,ttl,len,peer,fanout,rssi,mode,n_links,batt,temp,sys_saver`，意思見 [00 §3.2](00-setup-and-instrumentation.md#32-實驗工具)。

## 看手機上的 exp.csv（不用拉回筆電）

```bash
# 目前有幾列
adb shell run-as com.bitchat.droid wc -l files/exp.csv

# 最後 20 列
adb shell run-as com.bitchat.droid tail -n 20 files/exp.csv

# 收到幾筆 Health Report（不含重複）
adb shell run-as com.bitchat.droid cat files/exp.csv | grep -c ',RX,0x30,'
```

清除與拉回 `exp.csv` 照 runbook 的「Session 開始」「Session 結束」做。

## 手機狀態

```bash
# app 有沒有在跑（有輸出數字＝在跑）
adb shell pidof com.bitchat.droid

# 裝的是哪一版、什麼時候裝的
adb shell dumpsys package com.bitchat.droid | grep -E 'versionName|lastUpdateTime'

# 電量與溫度（temperature 單位是 0.1 °C，320 = 32.0 °C）
adb shell dumpsys battery | grep -E 'level|temperature'

# 系統省電模式有沒有開（1＝開，0＝關）
adb shell settings get global low_power

# 記憶體用量（E3 用，記 TOTAL PSS）
adb shell dumpsys meminfo com.bitchat.droid
```

接著 USB 時手機算在充電，app 會是 PERFORMANCE 模式。量完要拔線，實驗畫面才會回到 BALANCED。

## 常見問題

| 狀況 | 原因與處理 |
|---|---|
| `adb: command not found` | PATH 沒設好，或設完沒重開終端機。見上面「把 adb 加進 PATH」 |
| `adb devices` 顯示 `unauthorized` | 手機上沒按「允許 USB 偵錯」。拔掉重插，看手機畫面 |
| `adb devices` 什麼都沒列出 | 換一條能傳資料的 USB 線（有些線只能充電）；確認 USB 偵錯有開 |
| `more than one device/emulator` | 接了好幾支，要加 `-s 序號` |
| `run-as: package not debuggable` | 裝到 release 版了。照 runbook「前一天」重新安裝 debug build |
| `No such file or directory`（exp.csv） | 還沒有任何實驗事件，或剛清掉。開 app 等一下就會重建 |
| 指令裡的 `/sdcard/...` 路徑變成 `C:/Program Files/Git/sdcard/...` | Git Bash 會自動轉換開頭是 `/` 的路徑。在指令前面加 `MSYS_NO_PATHCONV=1`，例如 `MSYS_NO_PATHCONV=1 adb shell ls /sdcard` |
