package com.bitchat.android.service

/**
 * Whether [MeshForegroundService] posts its ongoing notification again (#80).
 *
 * Android 14 lets the user swipe a foreground service's notification away; the service keeps
 * running without it. By default it stays dismissed. With [MeshNotificationState.autoRestore]
 * (the settings screen's "常駐通知被滑掉時立即恢復", off by default) the notification carries a
 * delete intent and is posted again the moment it is dismissed.
 */
internal enum class RepostTrigger {
    /** The user swiped the notification away (its delete intent fired). */
    DISMISSED,

    /** Auto-restore was switched; the notification is rebuilt so the new delete intent applies. */
    SETTING_CHANGED
}

internal data class MeshNotificationState(
    /** The service is promoted, so its notification is the one to repost. */
    val inForeground: Boolean,
    /** [MeshServicePreferences.isBackgroundEnabled]. */
    val backgroundEnabled: Boolean,
    /** The permissions the service needs to stay in the foreground. */
    val hasPermissions: Boolean,
    /** The user chose 結束; the notification must not come back. */
    val shuttingDown: Boolean,
    /** [MeshServicePreferences.isNotificationAutoRestoreEnabled]. */
    val autoRestore: Boolean
)

internal fun shouldRepostMeshNotification(trigger: RepostTrigger, state: MeshNotificationState): Boolean {
    val showing = state.inForeground && state.backgroundEnabled && state.hasPermissions && !state.shuttingDown
    return when (trigger) {
        RepostTrigger.DISMISSED -> showing && state.autoRestore
        RepostTrigger.SETTING_CHANGED -> showing
    }
}
