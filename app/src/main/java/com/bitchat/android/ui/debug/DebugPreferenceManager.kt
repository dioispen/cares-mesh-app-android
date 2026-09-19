package com.bitchat.android.ui.debug

import android.content.Context
import android.content.SharedPreferences

/**
 * SharedPreferences-backed persistence for debug settings.
 * Keeps the DebugSettingsManager stateless with regard to Android Context.
 */
object DebugPreferenceManager {
    /**
     * Wi‑Fi Aware 的出廠預設。上游把它當除錯開關所以預設 false；CARES 是災害應變用途，
     * 需要 Wi‑Fi Aware 的較長距離與高頻寬，因此預設開啟，使用者仍可在除錯面板關閉。
     *
     * 這裡是唯一的預設值來源：BitchatApplication（初始化 controller）、PermissionManager
     * （決定要不要一併索取 NEARBY_WIFI_DEVICES）與除錯 UI 都讀這個值，三者必須一致，
     * 否則會出現「預設開啟卻從不要權限」這種永遠啟動不了的狀態。
     */
    const val DEFAULT_WIFI_AWARE_ENABLED = true

    private const val PREFS_NAME = "bitchat_debug_settings"
    private const val KEY_VERBOSE = "verbose_logging"
    private const val KEY_GATT_SERVER = "gatt_server_enabled"
    private const val KEY_GATT_CLIENT = "gatt_client_enabled"
    private const val KEY_PACKET_RELAY = "packet_relay_enabled"
    private const val KEY_MAX_CONN_OVERALL = "max_connections_overall"
    private const val KEY_MAX_CONN_SERVER = "max_connections_server"
    private const val KEY_MAX_CONN_CLIENT = "max_connections_client"
    private const val KEY_SEEN_PACKET_CAP = "seen_packet_capacity"
    // GCS keys (no migration/back-compat)
    private const val KEY_GCS_MAX_BYTES = "gcs_max_filter_bytes"
    private const val KEY_GCS_FPR = "gcs_filter_fpr_percent"
    // Transport master toggles
    private const val KEY_BLE_ENABLED = "ble_enabled"
    private const val KEY_WIFI_AWARE_ENABLED = "wifi_aware_enabled"
    private const val KEY_WIFI_AWARE_VERBOSE = "wifi_aware_verbose"

    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun ready(): Boolean = ::prefs.isInitialized

    fun getVerboseLogging(default: Boolean = false): Boolean =
        if (ready()) prefs.getBoolean(KEY_VERBOSE, default) else default

    fun setVerboseLogging(value: Boolean) {
        if (ready()) prefs.edit().putBoolean(KEY_VERBOSE, value).apply()
    }

    fun getGattServerEnabled(default: Boolean = true): Boolean =
        if (ready()) prefs.getBoolean(KEY_GATT_SERVER, default) else default

    fun setGattServerEnabled(value: Boolean) {
        if (ready()) prefs.edit().putBoolean(KEY_GATT_SERVER, value).apply()
    }

    fun getGattClientEnabled(default: Boolean = true): Boolean =
        if (ready()) prefs.getBoolean(KEY_GATT_CLIENT, default) else default

    fun setGattClientEnabled(value: Boolean) {
        if (ready()) prefs.edit().putBoolean(KEY_GATT_CLIENT, value).apply()
    }

    fun getPacketRelayEnabled(default: Boolean = true): Boolean =
        if (ready()) prefs.getBoolean(KEY_PACKET_RELAY, default) else default

    fun setPacketRelayEnabled(value: Boolean) {
        if (ready()) prefs.edit().putBoolean(KEY_PACKET_RELAY, value).apply()
    }

    // Optional connection limits (0 or missing => use defaults)
    fun getMaxConnectionsOverall(default: Int = 8): Int =
        if (ready()) prefs.getInt(KEY_MAX_CONN_OVERALL, default) else default

    fun setMaxConnectionsOverall(value: Int) {
        if (ready()) prefs.edit().putInt(KEY_MAX_CONN_OVERALL, value).apply()
    }

    fun getMaxConnectionsServer(default: Int = 8): Int =
        if (ready()) prefs.getInt(KEY_MAX_CONN_SERVER, default) else default

    fun setMaxConnectionsServer(value: Int) {
        if (ready()) prefs.edit().putInt(KEY_MAX_CONN_SERVER, value).apply()
    }

    fun getMaxConnectionsClient(default: Int = 8): Int =
        if (ready()) prefs.getInt(KEY_MAX_CONN_CLIENT, default) else default

    fun setMaxConnectionsClient(value: Int) {
        if (ready()) prefs.edit().putInt(KEY_MAX_CONN_CLIENT, value).apply()
    }

    // Sync/GCS settings
    fun getSeenPacketCapacity(default: Int = 500): Int =
        if (ready()) prefs.getInt(KEY_SEEN_PACKET_CAP, default) else default

    fun setSeenPacketCapacity(value: Int) {
        if (ready()) prefs.edit().putInt(KEY_SEEN_PACKET_CAP, value).apply()
    }

    fun getGcsMaxFilterBytes(default: Int = 400): Int =
        if (ready()) prefs.getInt(KEY_GCS_MAX_BYTES, default) else default

    fun setGcsMaxFilterBytes(value: Int) {
        if (ready()) prefs.edit().putInt(KEY_GCS_MAX_BYTES, value).apply()
    }

    fun getGcsFprPercent(default: Double = 1.0): Double =
        if (ready()) java.lang.Double.longBitsToDouble(prefs.getLong(KEY_GCS_FPR, java.lang.Double.doubleToRawLongBits(default))) else default

    fun setGcsFprPercent(value: Double) {
        if (ready()) prefs.edit().putLong(KEY_GCS_FPR, java.lang.Double.doubleToRawLongBits(value)).apply()
    }

    // Transport toggles
    fun getBleEnabled(default: Boolean = true): Boolean =
        if (ready()) prefs.getBoolean(KEY_BLE_ENABLED, default) else default

    fun setBleEnabled(value: Boolean) {
        if (ready()) prefs.edit().putBoolean(KEY_BLE_ENABLED, value).apply()
    }

    fun getWifiAwareEnabled(default: Boolean = DEFAULT_WIFI_AWARE_ENABLED): Boolean =
        if (ready()) prefs.getBoolean(KEY_WIFI_AWARE_ENABLED, default) else default

    fun setWifiAwareEnabled(value: Boolean) {
        if (ready()) prefs.edit().putBoolean(KEY_WIFI_AWARE_ENABLED, value).apply()
    }

    fun getWifiAwareVerbose(default: Boolean = false): Boolean =
        if (ready()) prefs.getBoolean(KEY_WIFI_AWARE_VERBOSE, default) else default

    fun setWifiAwareVerbose(value: Boolean) {
        if (ready()) prefs.edit().putBoolean(KEY_WIFI_AWARE_VERBOSE, value).apply()
    }
}
