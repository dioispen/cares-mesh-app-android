package com.bitchat.android.util

import java.util.UUID

/**
 * Centralized application-wide constants.
 */
object AppConstants {
    // Packet time-to-live (hops)
    val MESSAGE_TTL_HOPS: UByte = 7u     // Default TTL for regular packets
    val SYNC_TTL_HOPS: UByte = 0u        // TTL for neighbor-only sync packets

    /**
     * Health Report（包括帶 SOS 的）送出時的 TTL：flood 最遠到第 4 跳。刻意低於 [MESSAGE_TTL_HOPS]
     * （#14），依據是 2026-11-18 四機實地試跑報告的 §11.1 與 §13.3 P1-7：
     *
     * - **TTL 只決定快的那條路，不決定到不到。** 每台裝置都把各 Reporter 最新的 Health Report 留在同步
     *   暫存，anti-entropy 同步（[SYNC_TTL_HOPS]）會一跳一跳把它帶到 TTL 範圍外。flood 每跳約 +50 ms；
     *   同步在新連線約 1 s 後補送，已連著的鏈路每跳最多 30 s。所以 TTL 決定的是「幾跳內能在約 1 秒內
     *   收到」。也因此 TTL 不是 Health Report 擴散範圍的上限，拿來當隱私半徑並不成立。
     * - **TTL ≤ 4 才能讓每一跳都保有轉發衰減。** 轉發前 TTL 先扣 1，扣完若仍 ≥
     *   [com.bitchat.android.mesh.RelayPolicy.unconditionalRelayTtl]（預設 4），Relay Decision 就跳過依
     *   網路規模的轉發機率。TTL 3 第一次轉發就降到 2，每一跳都走機率；TTL 7 會讓前 3 代轉發一律送出，
     *   大型 mesh 的 flood 成本跟著放大。`HealthReportBroadcastTest` 鎖住這個關係，只改一邊就會失敗。
     * - **SOS 暫不另設 TTL**（ADR-0004）：要不要提高，等 E1-C（7 機比較 TTL 3 與 7）與 policy-level
     *   模擬（ADR-0001）的結果再決定。
     *
     * 只有實驗發送器（#70）經 `HealthReportBroadcast.send(ttl = …)` 覆寫。
     */
    val HEALTH_REPORT_TTL_HOPS: UByte = 3u

    object Mesh {
        // Peer lifecycle
        const val STALE_PEER_TIMEOUT_MS: Long = 180_000L // 3 minutes
        const val PEER_CLEANUP_INTERVAL_MS: Long = 60_000L
        const val PEER_DISCONNECT_GRACE_MS: Long = 10_000L

        // BLE connection tracking
        const val CONNECTION_RETRY_DELAY_MS: Long = 5_000L
        const val MAX_CONNECTION_ATTEMPTS: Int = 3
        const val CONNECTION_CLEANUP_DELAY_MS: Long = 500L
        const val CONNECTION_CLEANUP_INTERVAL_MS: Long = 30_000L
        const val BROADCAST_CLEANUP_DELAY_MS: Long = 500L

        // 殭屍連線偵測（P0-2，2026-11-18 四機試跑 12.1：C 掛著 2–3 條連線 20 分鐘，一筆都沒收到）。
        // 一條鏈路超過這麼久沒收到任何封包，就在本機斷開讓它重連。門檻必須大於鄰居的心跳間隔，
        // 否則會誤殺安靜但正常的連線：鄰居每 30 s 在每條鏈路送一次 REQUEST_SYNC（它休眠時會拉長
        // 到約 60 s），背景時 ANNOUNCE 間隔是 60–300 s，不能拿來當心跳。時間以不含深度睡眠的
        // 單調時鐘計，本機睡著的那段不算閒置。
        const val LINK_IDLE_TIMEOUT_MS: Long = 90_000L
        // 多久檢查一次；一條鏈路最晚在門檻後再過一個間隔被斷開。
        const val LINK_IDLE_CHECK_INTERVAL_MS: Long = 15_000L

        object Gatt {
            val SERVICE_UUID: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
            val CHARACTERISTIC_UUID: UUID = UUID.fromString("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
            val DESCRIPTOR_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        }
    }

    object Sync {
        const val CLEANUP_INTERVAL_MS: Long = 60_000L
        // How long each sender's latest Health Report stays in the sync set, counted from the
        // packet timestamp. Long enough for a Rescuer to walk into range within tens of minutes,
        // short enough that reports from people who left or changed Status don't linger (#91).
        const val HEALTH_REPORT_RETENTION_MS: Long = 2 * 60 * 60 * 1000L
        // How far ahead of our clock a Health Report's timestamp may be and still enter the sync
        // set. Its age is counted by our own clock, so a report from a phone whose clock runs
        // hours fast would otherwise stay that much longer than the retention period. The
        // 2026-11-18 trial measured at most 1.3 s between four phones; 10 min matches the ANNOUNCE
        // skew limit (AnnouncementIdentityValidator) and the mesh_reports rule for reportTime,
        // and keeps any report at most 2 h 10 min.
        const val HEALTH_REPORT_MAX_FUTURE_SKEW_MS: Long = 10 * 60 * 1000L
        // A standing Health Report (SOS raised, or Status 輕傷/重傷) is sent again, newly signed
        // and timestamped, this long after the last send (ADR-0012). Must stay well below
        // HEALTH_REPORT_RETENTION_MS: four sends per retention period, so the report outlives a
        // re-send that reached nobody or a wait that Doze stretched.
        const val STANDING_REPORT_RESEND_INTERVAL_MS: Long = 30 * 60 * 1000L
        // Upper bound on senders whose signing key is remembered, after they leave, for verifying
        // their synced Health Reports (#95). Well above the sync set's per-sender capacity.
        const val MAX_HEALTH_REPORT_SIGNING_KEYS: Int = 1_000
        // sync 集合上限 for Admin Notices (docs/ADMIN_NOTICE_V1.md「參數」): past it, the one with the
        // earliest expiresAt goes. Also bounds what the Inbox keeps to hand a new mesh service (#138).
        const val ADMIN_NOTICE_CAPACITY: Int = 50
    }

    object Fragmentation {
        const val FRAGMENT_SIZE_THRESHOLD: Int = 512
        const val MAX_FRAGMENT_SIZE: Int = 469
        const val FRAGMENT_TIMEOUT_MS: Long = 30_000L
        const val CLEANUP_INTERVAL_MS: Long = 10_000L
        const val MAX_FRAGMENTS_PER_ID: Int = 256
        const val MAX_FRAGMENT_TOTAL_BYTES: Int = 1_048_576
        const val MAX_ACTIVE_FRAGMENT_SETS: Int = 64
        const val MAX_GLOBAL_FRAGMENT_TOTAL_BYTES: Long = 4L * 1_048_576L
    }

    object Security {
        const val MESSAGE_TIMEOUT_MS: Long = 300_000L
        const val CLEANUP_INTERVAL_MS: Long = 300_000L
        const val MAX_PROCESSED_MESSAGES: Int = 10_000
        const val MAX_PROCESSED_KEY_EXCHANGES: Int = 1_000
        const val KEY_EXCHANGE_DEDUP_TIMEOUT_MS: Long = 60_000L
    }

    object Noise {
        const val REKEY_TIME_LIMIT_MS: Long = 3_600_000L // 1 hour
        const val REKEY_MESSAGE_LIMIT_ENCRYPTION: Long = 1_000L // per session, encryption service policy
        const val REKEY_MESSAGE_LIMIT_SESSION: Long = 10_000L // session-level ceiling
        const val MAX_PAYLOAD_SIZE_BYTES: Int = 256
        const val HIGH_NONCE_WARNING_THRESHOLD: Long = 1_000_000_000L
    }

    object Verification {
        const val QR_MAX_AGE_SECONDS: Long = 300L // 5 minutes
    }

    object Protocol {
        const val COMPRESSION_THRESHOLD_BYTES: Int = 100
        const val MAX_PAYLOAD_LENGTH: Int = 10_485_760
    }

    object StoreForward {
        const val MESSAGE_CACHE_TIMEOUT_MS: Long = 43_200_000L // 12h
        const val MAX_CACHED_MESSAGES: Int = 100
        const val MAX_CACHED_MESSAGES_FAVORITES: Int = 1_000
        const val CLEANUP_INTERVAL_MS: Long = 600_000L
    }

    object Power {
        const val CRITICAL_BATTERY_PERCENT: Int = 10
        const val LOW_BATTERY_PERCENT: Int = 20
        const val MEDIUM_BATTERY_PERCENT: Int = 50
        const val SCAN_ON_DURATION_NORMAL_MS: Long = 8_000L
        const val SCAN_OFF_DURATION_NORMAL_MS: Long = 2_000L
        const val SCAN_ON_DURATION_POWER_SAVE_MS: Long = 2_000L
        const val SCAN_OFF_DURATION_POWER_SAVE_MS: Long = 28_000L
        const val SCAN_ON_DURATION_ULTRA_LOW_MS: Long = 1_000L
        const val SCAN_OFF_DURATION_ULTRA_LOW_MS: Long = 29_000L
        const val MAX_CONNECTIONS_NORMAL: Int = 8
        const val MAX_CONNECTIONS_POWER_SAVE: Int = 8
        const val MAX_CONNECTIONS_ULTRA_LOW: Int = 8
    }

    object Nostr {
        // Set to false to disable all Nostr relay connections (unrelated to BLE mesh)
        const val ENABLED = false

        // Relay backoff
        const val INITIAL_BACKOFF_INTERVAL_MS: Long = 1_000L
        const val MAX_BACKOFF_INTERVAL_MS: Long = 300_000L
        const val BACKOFF_MULTIPLIER: Double = 2.0
        const val MAX_RECONNECT_ATTEMPTS: Int = 10

        // Transport
        const val READ_ACK_INTERVAL_MS: Long = 350L

        // Deduplicator
        const val DEFAULT_DEDUP_CAPACITY: Int = 10_000

        // Relay subscription validation
        const val SUBSCRIPTION_VALIDATION_INTERVAL_MS: Long = 30_000L
    }

    object Tor {
        const val DEFAULT_SOCKS_PORT: Int = 9060
        const val RESTART_DELAY_MS: Long = 2_000L
        const val INACTIVITY_TIMEOUT_MS: Long = 5_000L
        const val MAX_RETRY_ATTEMPTS: Int = 5
        const val STOP_TIMEOUT_MS: Long = 7_000L
    }

    object UI {
        const val MAX_NICKNAME_LENGTH: Int = 15
        const val BASE_FONT_SIZE_SP: Int = 14
        const val MESSAGE_DEDUP_TIMEOUT_MS: Long = 30_000L
        const val SYSTEM_EVENT_DEDUP_TIMEOUT_MS: Long = 5_000L
        const val ACTION_FORCE_FINISH: String = "com.bitchat.android.ACTION_FORCE_FINISH"
        const val PERMISSION_FORCE_FINISH: String = "com.bitchat.android.permission.FORCE_FINISH"
    }

    object Media {
        // A file is currently encoded into one protocol payload before BLE fragmentation.
        // Reserve room for maximum filename/MIME TLVs and encryption envelope overhead.
        const val MAX_FILE_SIZE_BYTES: Long = (10L * 1024 * 1024) - (132L * 1024)
    }

    object Router {
        const val OUTBOX_TICK_MS: Long = 2_000L
        const val OUTBOX_MESSAGE_TTL_MS: Long = 86_400_000L // 24 hours
        const val OUTBOX_MAX_PER_PEER: Int = 100
        val HANDSHAKE_RETRY_BACKOFF_MS: LongArray = longArrayOf(5_000L, 15_000L, 30_000L, 60_000L)
    }

    object Services {
        const val SEEN_MESSAGE_MAX_IDS: Int = 10_000
    }
}
