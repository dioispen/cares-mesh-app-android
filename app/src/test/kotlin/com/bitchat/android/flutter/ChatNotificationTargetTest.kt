package com.bitchat.android.flutter

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.pm.ShortcutManagerCompat
import com.bitchat.android.testsupport.FakeAndroidKeyStore
import com.bitchat.android.testsupport.ResourcelessContext
import com.bitchat.android.ui.NotificationManager
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Upstream's chat notifications as the Flutter entry receives them (#57): every one opens
 * [FlutterChatActivity], never upstream's Compose `MainActivity`, and carries extras that
 * [ChatNavigation.fromNotification] turns into the right Flutter screen. Also pins upstream's rule
 * for when a private message notification is posted at all, as the Flutter entry drives it
 * (`ForegroundMeshDelegate` decides which [NotificationManager] posts; `chat_startPrivateChat` /
 * `chat_endPrivateChat` set the chat in view).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class ChatNotificationTargetTest {

    private lateinit var context: Context
    private lateinit var system: android.app.NotificationManager
    private lateinit var notifications: NotificationManager

    @Before
    fun setUp() {
        // ConversationListPreferences (mute state) sits in the Keystore-backed identity store.
        FakeAndroidKeyStore.install()
        context = ResourcelessContext(RuntimeEnvironment.getApplication())
        system = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        system.cancelAll()
        notifications = NotificationManager(context, NotificationManagerCompat.from(context))
    }

    @After
    fun tearDown() {
        FakeAndroidKeyStore.uninstall()
    }

    // --- where a tap goes ---------------------------------------------------------------------

    @Test
    fun `a private message notification opens the Flutter entry at that private chat`() {
        notifications.showPrivateMessageNotification(ALICE, "alice", "hello")

        val tap = tapOf(posted(ALICE.hashCode()))

        assertEquals(FlutterChatActivity::class.java.name, tap.component?.className)
        assertEquals(ChatNavigation.PrivateChat(ALICE, "alice"), ChatNavigation.fromNotification(tap))
    }

    @Test
    fun `a tap brings back the running entry instead of stacking a new one`() {
        // With launchMode singleTop the running Activity gets onNewIntent; clearing the top drops
        // anything above it in the task.
        notifications.showPrivateMessageNotification(ALICE, "alice", "hello")

        val flags = tapOf(posted(ALICE.hashCode())).flags

        assertEquals(Intent.FLAG_ACTIVITY_SINGLE_TOP, flags and Intent.FLAG_ACTIVITY_SINGLE_TOP)
        assertEquals(Intent.FLAG_ACTIVITY_CLEAR_TOP, flags and Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }

    @Test
    fun `the conversation shortcut published with it opens the Flutter entry too`() {
        notifications.showPrivateMessageNotification(CONTACT, "alice", "hello")

        val shortcut = ShortcutManagerCompat.getDynamicShortcuts(context).single()

        assertEquals(FlutterChatActivity::class.java.name, shortcut.intent.component?.className)
        assertEquals(ChatNavigation.PrivateChat(CONTACT, "alice"), ChatNavigation.fromNotification(shortcut.intent))
    }

    @Test
    fun `a mention notification opens the Flutter entry at the public chat`() {
        // Posted only while another chat is in view (see the rules below).
        notifications.setCurrentPrivateChatPeer(BOB)

        notifications.showMeshMentionNotification("alice", "@me look", ALICE)
        val tap = tapOf(posted(MESH_MENTION_NOTIFICATION_ID))

        assertEquals(FlutterChatActivity::class.java.name, tap.component?.className)
        assertEquals(ChatNavigation.PublicChat, ChatNavigation.fromNotification(tap))
    }

    @Test
    fun `the summary of several conversations brings the Flutter entry to the front`() {
        notifications.showPrivateMessageNotification(ALICE, "alice", "hello")
        notifications.showPrivateMessageNotification(BOB, "bob", "hi")

        val tap = tapOf(posted(DM_SUMMARY_NOTIFICATION_ID))

        assertEquals(FlutterChatActivity::class.java.name, tap.component?.className)
        assertNull("no single chat to open", ChatNavigation.fromNotification(tap))
    }

    @Test
    fun `a verification notification about a peer opens that private chat, as upstream`() {
        notifications.showVerificationNotification("Verified", "alice", ALICE)

        val tap = tapOf(shadowOf(system).allNotifications.single())

        assertEquals(FlutterChatActivity::class.java.name, tap.component?.className)
        assertEquals(ChatNavigation.PrivateChat(ALICE, "alice"), ChatNavigation.fromNotification(tap))
    }

    @Test
    fun `geohash notifications open the Flutter entry without a destination`() {
        // Flutter has no geohash chat (P3), and with Nostr off none arrive; the tap only brings
        // the app back instead of opening upstream's Compose UI.
        notifications.showGeohashNotification("u4pruyd", "alice", "hello", isMention = true)
        notifications.showGeohashNotification("u4pruy", "bob", "hi")

        listOf(GEOHASH_NOTIFICATION_BASE + "u4pruyd".hashCode(), GEOHASH_SUMMARY_NOTIFICATION_ID).forEach { id ->
            val tap = tapOf(posted(id))

            assertEquals(FlutterChatActivity::class.java.name, tap.component?.className)
            assertNull(ChatNavigation.fromNotification(tap))
        }
    }

    @Test
    fun `reopening from recents a task a notification started goes nowhere`() {
        notifications.showPrivateMessageNotification(ALICE, "alice", "hello")
        val relaunch = Intent(tapOf(posted(ALICE.hashCode())))
            .addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)

        assertNull(ChatNavigation.fromNotification(relaunch))
    }

    // --- when a private message notification is posted ---------------------------------------

    @Test
    fun `in front, the private chat being viewed gets no notification`() {
        // ChatViewModel's own manager: the delegate is attached (resumed) and the Flutter private
        // chat screen has started its chat.
        notifications.setCurrentPrivateChatPeer(ALICE)

        notifications.showPrivateMessageNotification(ALICE, "alice", "hello")

        assertNull(shadowOf(system).getNotification(ALICE.hashCode()))
    }

    @Test
    fun `in front, other chats still notify`() {
        notifications.setCurrentPrivateChatPeer(ALICE)

        notifications.showPrivateMessageNotification(BOB, "bob", "hi")

        assertNotNull(shadowOf(system).getNotification(BOB.hashCode()))
    }

    @Test
    fun `a private chat left again notifies again`() {
        notifications.setCurrentPrivateChatPeer(ALICE)
        notifications.setCurrentPrivateChatPeer(null)

        notifications.showPrivateMessageNotification(ALICE, "alice", "hello")

        assertNotNull(shadowOf(system).getNotification(ALICE.hashCode()))
    }

    @Test
    fun `in the background the mesh service notifies even for the chat left open`() {
        // BluetoothMeshService with no delegate (paused Flutter entry): its own manager, marked
        // as in the background just before posting.
        notifications.setCurrentPrivateChatPeer(ALICE)

        notifications.setAppBackgroundState(true)
        notifications.showPrivateMessageNotification(ALICE, "alice", "hello")
        val tap = tapOf(posted(ALICE.hashCode()))

        assertEquals(FlutterChatActivity::class.java.name, tap.component?.className)
        assertEquals(ChatNavigation.PrivateChat(ALICE, "alice"), ChatNavigation.fromNotification(tap))
    }

    @Test
    fun `no mention notification while the public chat is in view`() {
        notifications.showMeshMentionNotification("alice", "@me look", ALICE)

        assertNull(shadowOf(system).getNotification(MESH_MENTION_NOTIFICATION_ID))
    }

    private fun posted(id: Int): Notification =
        shadowOf(system).getNotification(id) ?: throw AssertionError("no notification $id was posted")

    private fun tapOf(notification: Notification): Intent =
        shadowOf(notification.contentIntent).savedIntent

    private companion object {
        const val ALICE = "1111111111111111"
        const val BOB = "2222222222222222"
        val CONTACT = "contact_" + "a".repeat(64)

        // ui.NotificationManager's private notification IDs.
        const val DM_SUMMARY_NOTIFICATION_ID = 999
        const val GEOHASH_SUMMARY_NOTIFICATION_ID = 998
        const val GEOHASH_NOTIFICATION_BASE = 3000
        const val MESH_MENTION_NOTIFICATION_ID = 4000
    }
}
