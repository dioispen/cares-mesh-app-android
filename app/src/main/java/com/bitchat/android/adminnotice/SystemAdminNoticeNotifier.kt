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
 * Each notice is posted under its messageId as the tag, so #139 can update or cancel it.
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
        val openApp = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            Intent(context, FlutterChatActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(context, channelId(notice.level))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(texts.title(notice.level))
            .setContentText(notice.content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(notice.content))
            .setWhen(notice.issuedAtMs)
            .setShowWhen(true)
            .setContentIntent(openApp)
            .setAutoCancel(true)
            // A correction (#139) updates this notification without sounding again.
            .setOnlyAlertOnce(true)
            .setPriority(priority(notice.level))
            // A broadcast is public by design; a targeted notice's content (#141) is not.
            .setVisibility(
                if (notice.kind == AdminNoticeKind.BROADCAST) {
                    NotificationCompat.VISIBILITY_PUBLIC
                } else {
                    NotificationCompat.VISIBILITY_PRIVATE
                }
            )
            .build()
        try {
            notificationManager.notify(notice.messageId, NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "Notification permission withdrawn before Admin Notice ${notice.messageId} was posted")
        }
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
