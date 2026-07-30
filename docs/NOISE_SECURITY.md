# Noise Protocol 加密機制說明

本文件說明 bitchat-android 私訊通道的完整加密架構與安全屬性。

## 使用協議

```
Noise_XX_25519_ChaChaPoly_SHA256
```

| 元件 | 選擇 |
|------|------|
| 握手模式 | XX（雙向身份認證） |
| DH 演算法 | Curve25519 |
| 對稱加密 | ChaCha20-Poly1305 |
| 雜湊函數 | SHA-256 |

---

## 第一層：金鑰體系

每個裝置持有兩組獨立的長期金鑰，儲存於 Android `EncryptedSharedPreferences`（AES-256-GCM 保護）：

| 金鑰類型 | 演算法 | 用途 |
|----------|--------|------|
| 靜態身份金鑰 (static key) | Curve25519（32 bytes） | Noise 握手中的身份認證 |
| 簽章金鑰 (signing key) | Ed25519（32 bytes） | 封包層級數位簽章 |

兩組金鑰跨 App 重啟持久保存，構成使用者的永久身份。觸發 Panic Mode 時兩組金鑰同時清除並重新生成。

---

## 第二層：Noise XX 握手（三次往返）

XX 模式中，雙方的靜態公鑰均在握手過程中傳遞並完成認證，是 Noise 協議中最完整的互認身份模式。

```
Initiator (Alice)                   Responder (Bob)
─────────────────────────────────────────────────────────
生成臨時金鑰 e_A

MSG 1 →  e_A (32 bytes)
                                    接收 e_A
                                    生成臨時金鑰 e_B
                                    計算 ee = DH(e_B, e_A)   ← 建立前向保密通道
                                    用 ee 加密靜態公鑰 s_B
                                    計算 es = DH(s_B, e_A)   ← 認證 Bob 靜態身份

         ← MSG 2  e_B + enc(s_B) + enc(空 payload)  (96 bytes)

計算 ee = DH(e_A, e_B)
計算 es = DH(e_A, s_B)             ← 驗證 Bob 身份
用 ee + es 加密靜態公鑰 s_A
計算 se = DH(s_A, e_B)             ← 認證 Alice 靜態身份

MSG 3 →  enc(s_A) + enc(空 payload)  (48 bytes)
                                    計算 se = DH(e_B, s_A)   ← 驗證 Alice 身份

雙方呼叫 split()，派生兩條獨立的 CipherState：
  sendCipher    (Initiator 傳送 / Responder 接收)
  receiveCipher (Initiator 接收 / Responder 傳送)
```

握手完成後，`HandshakeState` 物件立即銷毀，臨時金鑰材料從記憶體清除，達成**前向保密（Forward Secrecy）**。  
握手雜湊值（`handshakeHash`）保留作為 Channel Binding，可防止中間人攻擊注入已建立的握手內容。

---

## 第三層：傳輸加密（ChaCha20-Poly1305）

握手後每條私訊的封包格式：

```
[nonce : 4 bytes, big-endian] [ciphertext + Poly1305 MAC : N + 16 bytes]
```

### 加密流程

```
sendCipher.setNonce(messagesSent)
ciphertext = encryptWithAd(null, plaintext)   // ChaCha20 + Poly1305 MAC (16 bytes)
combinedPayload = nonceBytes(4) + ciphertext
messagesSent++
```

### 解密流程

```
extractedNonce = combinedPayload[0..3]        // 取出 nonce
ciphertext     = combinedPayload[4..]

// 滑動視窗防重播檢查
if !isValidNonce(extractedNonce): reject

receiveCipher.setNonce(extractedNonce)
plaintext = decryptWithAd(null, ciphertext)   // Poly1305 驗證 + ChaCha20 解密
markNonceAsSeen(extractedNonce)               // 更新視窗
```

### 防重播攻擊（Sliding Window）

維護 1024-slot（128 bytes）bitmap，每個 bit 對應一個 nonce 是否已處理過。視窗之外（超過 1024 個 nonce 差距）的封包一律拒絕。

### Rekey 觸發條件

滿足任一條件即重新執行 XX 握手，派生新的 CipherState：

| 條件 | 閾值 |
|------|------|
| 工作階段時間 | 超過 1 小時 |
| 累積訊息數 | 超過 10,000 則 |

---

## 第四層：頻道加密（密碼保護群組頻道）

密碼保護頻道使用獨立機制，不走 Noise 握手：

### 金鑰推導

```
PBKDF2(
  PRF       = HMAC-SHA256,
  password  = 使用者輸入密碼,
  salt      = channelName.UTF-8,
  iterations= 100,000,
  keyLen    = 256 bits
) → AES-256 SecretKey
```

### 加密格式

```
[IV : 12 bytes, 隨機] [ciphertext + GCM AuthTag : N + 16 bytes]
```

演算法：`AES/GCM/NoPadding`，AuthTag 長度 128 bits。

---

## 安全屬性總覽

| 屬性 | 實現方式 |
|------|----------|
| 端對端加密 | Noise XX 握手 + ChaCha20-Poly1305 傳輸 |
| 前向保密 | 握手後立即銷毀臨時金鑰 |
| 雙向身份認證 | XX 模式三次握手，雙方靜態公鑰均經 DH 認證 |
| 防重播攻擊 | 1024-slot 滑動視窗 bitmap |
| 封包完整性 | Poly1305 MAC（每條訊息）+ Ed25519 封包簽章 |
| 密碼保護頻道 | PBKDF2（100k iter）+ AES-256-GCM |
| 金鑰儲存安全 | Android EncryptedSharedPreferences（AES-256-GCM） |
| 身份持久化與清除 | Curve25519 / Ed25519 靜態金鑰跨重啟保存，Panic Mode 一鍵清除 |

---

## 相關原始碼

| 檔案 | 說明 |
|------|------|
| [NoiseSession.kt](../app/src/main/java/com/bitchat/android/noise/NoiseSession.kt) | 單一 Peer 的 Noise 握手與傳輸加密實作 |
| [NoiseEncryptionService.kt](../app/src/main/java/com/bitchat/android/noise/NoiseEncryptionService.kt) | 多 Peer 工作階段管理、金鑰生成、封包簽章 |
| [NoiseChannelEncryption.kt](../app/src/main/java/com/bitchat/android/noise/NoiseChannelEncryption.kt) | 密碼保護頻道的 PBKDF2 + AES-GCM 加密 |
| [EncryptionService.kt](../app/src/main/java/com/bitchat/android/crypto/EncryptionService.kt) | 對外統一加密介面，包裝 NoiseEncryptionService |
