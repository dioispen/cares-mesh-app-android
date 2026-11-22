package com.bitchat.android.adminnotice

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.bitchat.android.R
import com.bitchat.android.flutter.FlutterChatActivity

/** The user-visible words of Admin Notice notifications; resources in production, fixed in tests. */
interface AdminNoticeTexts {
    fun groupName(): String
    fun channelName(level: AdminNoticeLevel): String
    fun channelDescription(level: AdminNoticeLevel): String
    fun title(level: AdminNoticeLevel): String

    /** What the lock screen shows in place of a targeted notice's content. */
    fun hiddenContent(): String
}

private class ResourceAdminNoticeTexts(private val context: Context) : AdminNoticeTexts {
    override fun groupName() = context.getString(R.string.admin_notice_channel_group)

    override fun channelName(level: AdminNoticeLevel) = context.getString(
        when (level) {
            AdminNoticeLevel.URGENT -> R.string.admin_notice_channel_urgent
            AdminNoticeLevel.IMPORTANT -> R.string.admin_notice_channel_important
            AdminNoticeLevel.INFO -> R.string.admin_notice_channel_info
        }
    )

    override fun channelDescription(level: AdminNoticeLevel) = context.getString(
        when (level) {
            AdminNoticeLevel.URGENT -> R.string.admin_notice_channel_urgent_desc
            AdminNoticeLevel.IMPORTANT -> R.string.admin_notice_channel_important_desc
            AdminNoticeLevel.INFO -> R.string.admin_notice_channel_info_desc
        }
    )

    override fun title(level: AdminNoticeLevel) = context.getString(
        when (level) {
            AdminNoticeLevel.URGENT -> R.string.admin_notice_title_urgent
            AdminNoticeLevel.IMPORTANT -> R.string.admin_notice_title_important
            AdminNoticeLevel.INFO -> R.string.admin_notice_title_info
        }
    )

    override fun hiddenContent() = context.getString(R.string.admin_notice_targeted_hidden)
}

/**
 * Admin Notice notifications (收件端呈現): one channel per level, created at construction so users
 * find them in the system settings before the first notice.
 *
 * - 緊急: high importance, sound and vibration. Never bypasses Do Not Disturb, and posts no
 *   category, since DND exceptions for alarms, events or messages would let it through.
 * - 重要: default importance.
 * - 資訊: low importance, silent.
 *
 * A broadcast shows its content on the lock screen. A targeted notice (#141) is private with a
 * public version that shows only its level ([AdminNoticeTexts.hiddenContent]); Android uses that
 * version on a secure lock screen unless the user lets the lock screen show sensitive content.
 *
 * Each notice is posted under its messageId as the tag, so a correction or withdrawal can cancel it.
 * Tapping one opens the App on the Admin Notice list ([EXTRA_OPEN_ADMIN_NOTICES]), running or not.
 * POST_NOTIFICATIONS is optional: without it nothing is posted, and the home screen's notice card
 * (#142) stands in.
 */
class SystemAdminNoticeNotifier(
    private val context: Context,
    private val texts: AdminNoticeTexts = ResourceAdminNoticeTexts(context),
    private val notificationManager: NotificationManagerCompat = NotificationManagerCompat.from(context)
) : AdminNoticeNotifier {

    init {
        createChannels()
    }

    @SuppressLint("MissingPermission") // checked by canPostNotifications()
    override fun notify(notice: ReceivedAdminNotice) {
        if (!canPostNotifications()) {
            Log.i(TAG, "Notifications are off; Admin Notice ${notice.messageId} is only stored")
            return
        }
        // One PendingIntent for every notice: each opens the list, which shows them all in full.
        val openList = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            Intent(context, FlutterChatActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_OPEN_ADMIN_NOTICES, true)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = NotificationCompat.Builder(context, channelId(notice.level))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(texts.title(notice.level))
            .setContentText(notice.content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(notice.content))
            .setWhen(notice.issuedAtMs)
            .setShowWhen(true)
            .setContentIntent(openList)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setPriority(priority(notice.level))
        if (notice.kind == AdminNoticeKind.BROADCAST) {
            // A broadcast is public by design: every device in range can read it anyway.
            builder.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        } else {
            // A targeted notice's content is for its recipient: a secure lock screen shows only its
            // level, and an explicit public version keeps that independent of each launcher.
            builder.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(
                    NotificationCompat.Builder(context, channelId(notice.level))
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle(texts.title(notice.level))
                        .setContentText(texts.hiddenContent())
                        .setWhen(notice.issuedAtMs)
                        .setShowWhen(true)
                        .setContentIntent(openList)
                        .setAutoCancel(true)
                        .setPriority(priority(notice.level))
                        .build()
                )
        }
        val notification = builder.build()
        try {
            notificationManager.notify(notice.messageId, NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "Notification permission withdrawn before Admin Notice ${notice.messageId} was posted")
        }
    }

    /** A corrected or withdrawn notice: its notification, found by its messageId as the tag, goes. */
    override fun cancel(messageId: String) {
        notificationManager.cancel(messageId, NOTIFICATION_ID)
    }

    private fun canPostNotifications(): Boolean =
        notificationManager.areNotificationsEnabled() &&
            (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
                )

    private fun createChannels() {
        val system = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        system.createNotificationChannelGroup(NotificationChannelGroup(CHANNEL_GROUP_ID, texts.groupName()))
        system.createNotificationChannels(AdminNoticeLevel.entries.map(::channel))
    }

    private fun channel(level: AdminNoticeLevel): NotificationChannel {
        val importance = when (level) {
            AdminNoticeLevel.URGENT -> NotificationManager.IMPORTANCE_HIGH
            AdminNoticeLevel.IMPORTANT -> NotificationManager.IMPORTANCE_DEFAULT
            AdminNoticeLevel.INFO -> NotificationManager.IMPORTANCE_LOW
        }
        return NotificationChannel(channelId(level), texts.channelName(level), importance).apply {
            description = texts.channelDescription(level)
            group = CHANNEL_GROUP_ID
            setBypassDnd(false)
            when (level) {
                AdminNoticeLevel.URGENT -> {
                    setSound(
                        Settings.System.DEFAULT_NOTIFICATION_URI,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    enableVibration(true)
                }
                AdminNoticeLevel.IMPORTANT -> Unit
                AdminNoticeLevel.INFO -> {
                    setSound(null, null)
                    enableVibration(false)
                }
            }
        }
    }

    companion object {
        private const val TAG = "AdminNoticeNotifier"
        private const val CHANNEL_GROUP_ID = "admin_notices"

        /** With the messageId as tag; one ID for all notices keeps clear of the App's other notifications. */
        const val NOTIFICATION_ID = 3101

        /**
         * The tap's intent extra: open the Admin Notice list (`AppNavigation.AdminNotices`), as
         * upstream's chat notifications name theirs (`ui.NotificationManager.EXTRA_OPEN_MESH_CHAT`).
         */
        const val EXTRA_OPEN_ADMIN_NOTICES = "open_admin_notices"

        fun channelId(level: AdminNoticeLevel): String = when (level) {
            AdminNoticeLevel.URGENT -> "admin_notice_urgent"
            AdminNoticeLevel.IMPORTANT -> "admin_notice_important"
            AdminNoticeLevel.INFO -> "admin_notice_info"
        }

        private fun priority(level: AdminNoticeLevel): Int = when (level) {
            AdminNoticeLevel.URGENT -> NotificationCompat.PRIORITY_HIGH
            AdminNoticeLevel.IMPORTANT -> NotificationCompat.PRIORITY_DEFAULT
            AdminNoticeLevel.INFO -> NotificationCompat.PRIORITY_LOW
        }
    }
}
