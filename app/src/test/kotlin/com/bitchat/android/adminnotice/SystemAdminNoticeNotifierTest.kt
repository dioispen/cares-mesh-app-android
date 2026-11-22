package com.bitchat.android.adminnotice

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import com.bitchat.android.flutter.AppNavigation
import com.bitchat.android.flutter.FlutterChatActivity
import com.bitchat.android.testsupport.TestAdminNotices
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * One notification channel per level (收件端呈現): 緊急 is high importance with sound and vibration
 * and does not bypass Do Not Disturb, 重要 is default, 資訊 is low and silent. POST_NOTIFICATIONS is
 * optional: without it nothing is posted and nothing breaks.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.TIRAMISU], manifest = Config.NONE)
class SystemAdminNoticeNotifierTest {

    private val application: Application = RuntimeEnvironment.getApplication()
    private val system = application.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun notifier() = SystemAdminNoticeNotifier(application, texts = FakeTexts)

    @Test
    fun `the urgent channel is high importance, sounds and vibrates, and respects Do Not Disturb`() {
        notifier()

        val channel = system.getNotificationChannel(SystemAdminNoticeNotifier.channelId(AdminNoticeLevel.URGENT))!!
        assertEquals(NotificationManager.IMPORTANCE_HIGH, channel.importance)
        assertNotNull(channel.sound)
        assertTrue(channel.shouldVibrate())
        assertFalse(channel.canBypassDnd())
        assertEquals("channel 緊急", channel.name)
    }

    @Test
    fun `the important channel has default importance`() {
        notifier()

        val channel = system.getNotificationChannel(SystemAdminNoticeNotifier.channelId(AdminNoticeLevel.IMPORTANT))!!
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, channel.importance)
        assertFalse(channel.canBypassDnd())
    }

    @Test
    fun `the info channel is low importance and silent`() {
        notifier()

        val channel = system.getNotificationChannel(SystemAdminNoticeNotifier.channelId(AdminNoticeLevel.INFO))!!
        assertEquals(NotificationManager.IMPORTANCE_LOW, channel.importance)
        assertNull(channel.sound)
        assertFalse(channel.shouldVibrate())
    }

    @Test
    fun `a notice is posted on its level's channel under its messageId and opens the App`() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)

        notifier().notify(notice(AdminNoticeLevel.URGENT))

        val posted = shadowOf(system).getNotification(MESSAGE_ID, SystemAdminNoticeNotifier.NOTIFICATION_ID)!!
        assertEquals(SystemAdminNoticeNotifier.channelId(AdminNoticeLevel.URGENT), posted.channelId)
        assertEquals("title 緊急", posted.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(TestAdminNotices.V1_CONTENT, posted.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals(TestAdminNotices.VECTOR_ISSUED_AT, posted.`when`)
        assertEquals(Notification.VISIBILITY_PUBLIC, posted.visibility)
        assertEquals(
            FlutterChatActivity::class.java.name,
            shadowOf(posted.contentIntent).savedIntent.component?.className
        )
    }

    @Test
    fun `tapping a notice opens the Admin Notice list, bringing back the running entry`() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)

        notifier().notify(notice(AdminNoticeLevel.URGENT))

        val posted = shadowOf(system).getNotification(MESSAGE_ID, SystemAdminNoticeNotifier.NOTIFICATION_ID)!!
        val tap = shadowOf(posted.contentIntent).savedIntent
        assertEquals(AppNavigation.AdminNotices, AppNavigation.fromNotification(tap))
        // With launchMode singleTop the running Activity gets onNewIntent instead of a second one.
        assertEquals(Intent.FLAG_ACTIVITY_SINGLE_TOP, tap.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP)
        assertEquals(Intent.FLAG_ACTIVITY_CLEAR_TOP, tap.flags and Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }

    @Test
    fun `tapping a targeted notice on the lock screen opens the list too`() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)

        notifier().notify(notice(AdminNoticeLevel.IMPORTANT, kind = AdminNoticeKind.TARGETED))

        val lockScreen = shadowOf(system).getNotification(MESSAGE_ID, SystemAdminNoticeNotifier.NOTIFICATION_ID)!!.publicVersion!!
        assertEquals(AppNavigation.AdminNotices, AppNavigation.fromNotification(shadowOf(lockScreen.contentIntent).savedIntent))
    }

    @Test
    fun `a targeted notice keeps its content off the lock screen, which shows only its level`() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)

        notifier().notify(notice(AdminNoticeLevel.IMPORTANT, kind = AdminNoticeKind.TARGETED))

        val posted = shadowOf(system).getNotification(MESSAGE_ID, SystemAdminNoticeNotifier.NOTIFICATION_ID)!!
        assertEquals(Notification.VISIBILITY_PRIVATE, posted.visibility)
        assertEquals(TestAdminNotices.V1_CONTENT, posted.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        val lockScreen = posted.publicVersion!!
        assertEquals("title 重要", lockScreen.extras.getString(Notification.EXTRA_TITLE))
        assertEquals("hidden", lockScreen.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        val shownLocked = lockScreen.extras.keySet().joinToString { lockScreen.extras.get(it).toString() }
        assertFalse(shownLocked, shownLocked.contains(TestAdminNotices.V1_CONTENT))
        assertEquals(SystemAdminNoticeNotifier.channelId(AdminNoticeLevel.IMPORTANT), lockScreen.channelId)
    }

    @Test
    fun `a broadcast has no separate lock-screen version, since its content is public`() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)

        notifier().notify(notice(AdminNoticeLevel.URGENT))

        val posted = shadowOf(system).getNotification(MESSAGE_ID, SystemAdminNoticeNotifier.NOTIFICATION_ID)!!
        assertEquals(Notification.VISIBILITY_PUBLIC, posted.visibility)
        assertNull(posted.publicVersion)
    }

    @Test
    fun `each level posts on its own channel`() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val notifier = notifier()

        AdminNoticeLevel.entries.forEachIndexed { i, level -> notifier.notify(notice(level, messageId = "000000000000000${i + 1}")) }

        assertEquals(
            AdminNoticeLevel.entries.map { SystemAdminNoticeNotifier.channelId(it) },
            AdminNoticeLevel.entries.indices.map { i ->
                shadowOf(system).getNotification("000000000000000${i + 1}", SystemAdminNoticeNotifier.NOTIFICATION_ID)!!.channelId
            }
        )
        assertEquals(3, AdminNoticeLevel.entries.map { SystemAdminNoticeNotifier.channelId(it) }.toSet().size)
    }

    @Test
    fun `a notice's notification is cancelled by its messageId, the others stay`() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val notifier = notifier()
        notifier.notify(notice(AdminNoticeLevel.URGENT))
        notifier.notify(notice(AdminNoticeLevel.INFO, messageId = OTHER_MESSAGE_ID))

        notifier.cancel(MESSAGE_ID)

        assertNull(shadowOf(system).getNotification(MESSAGE_ID, SystemAdminNoticeNotifier.NOTIFICATION_ID))
        assertNotNull(shadowOf(system).getNotification(OTHER_MESSAGE_ID, SystemAdminNoticeNotifier.NOTIFICATION_ID))
    }

    @Test
    fun `cancelling a notice that was never posted does nothing`() {
        shadowOf(application).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)

        notifier().cancel(MESSAGE_ID)

        assertTrue(shadowOf(system).allNotifications.isEmpty())
    }

    @Test
    fun `without POST_NOTIFICATIONS nothing is posted and nothing breaks`() {
        shadowOf(application).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)

        notifier().notify(notice(AdminNoticeLevel.URGENT))

        assertTrue(shadowOf(system).allNotifications.isEmpty())
    }

    private fun notice(
        level: AdminNoticeLevel,
        messageId: String = MESSAGE_ID,
        kind: AdminNoticeKind = AdminNoticeKind.BROADCAST
    ) = ReceivedAdminNotice(
        messageId = messageId,
        kind = kind,
        level = level,
        issuedAtMs = TestAdminNotices.VECTOR_ISSUED_AT,
        expiresAtMs = TestAdminNotices.V1_EXPIRES_AT,
        replaces = null,
        content = TestAdminNotices.V1_CONTENT,
        source = AdminNoticeSource.BACKEND
    )

    private object FakeTexts : AdminNoticeTexts {
        override fun groupName() = "公告"
        override fun channelName(level: AdminNoticeLevel) = "channel ${label(level)}"
        override fun channelDescription(level: AdminNoticeLevel) = "description ${label(level)}"
        override fun title(level: AdminNoticeLevel) = "title ${label(level)}"
        override fun hiddenContent() = "hidden"

        private fun label(level: AdminNoticeLevel) = when (level) {
            AdminNoticeLevel.URGENT -> "緊急"
            AdminNoticeLevel.IMPORTANT -> "重要"
            AdminNoticeLevel.INFO -> "資訊"
        }
    }

    private companion object {
        const val MESSAGE_ID = TestAdminNotices.V1_MESSAGE_ID
        const val OTHER_MESSAGE_ID = "1122334455667788"
    }
}
