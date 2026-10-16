package com.bitchat.android.service

import android.content.Context
import android.content.SharedPreferences

object MeshServicePreferences {
    private const val PREFS_NAME = "bitchat_mesh_service_prefs"
    private const val KEY_AUTO_START = "auto_start_on_boot"
    private const val KEY_BACKGROUND_ENABLED = "background_enabled"
    private const val KEY_NOTIFICATION_AUTO_RESTORE = "notification_auto_restore"

    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun isAutoStartEnabled(default: Boolean = true): Boolean {
        return prefs.getBoolean(KEY_AUTO_START, default)
    }

    fun setAutoStartEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_AUTO_START, enabled).apply()
    }

    fun isBackgroundEnabled(default: Boolean = true): Boolean {
        return prefs.getBoolean(KEY_BACKGROUND_ENABLED, default)
    }

    fun setBackgroundEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_BACKGROUND_ENABLED, enabled).apply()
    }

    /**
     * Whether the ongoing notification is posted again as soon as the user swipes it away (#80).
     * Off by default: Android 14 deliberately lets the user dismiss a foreground service's
     * notification.
     */
    fun isNotificationAutoRestoreEnabled(default: Boolean = false): Boolean {
        return prefs.getBoolean(KEY_NOTIFICATION_AUTO_RESTORE, default)
    }

    fun setNotificationAutoRestoreEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_NOTIFICATION_AUTO_RESTORE, enabled).apply()
    }
}
