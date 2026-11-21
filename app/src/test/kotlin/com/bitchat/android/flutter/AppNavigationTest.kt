package com.bitchat.android.flutter

import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.ui.NotificationManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify
import org.mockito.kotlin.verifyNoMoreInteractions

/**
 * A tapped chat notification, as the Flutter entry reads it (#57): upstream's intent extras become
 * a [AppNavigation] that waits in [PendingAppNavigation] until Dart takes it.
 */
class AppNavigationTest {

    // --- reading upstream's notification extras ---------------------------------------------

    @Test
    fun `a private message notification opens that private chat`() {
        val navigation = parse(
            NotificationManager.EXTRA_OPEN_PRIVATE_CHAT to true,
            NotificationManager.EXTRA_PEER_ID to CONTACT,
            NotificationManager.EXTRA_SENDER_NICKNAME to "alice"
        )

        assertEquals(AppNavigation.PrivateChat(CONTACT, "alice"), navigation)
    }

    @Test
    fun `the sender nickname is optional`() {
        val navigation = parse(
            NotificationManager.EXTRA_OPEN_PRIVATE_CHAT to true,
            NotificationManager.EXTRA_PEER_ID to ALICE
        )

        assertEquals(AppNavigation.PrivateChat(ALICE, null), navigation)
    }

    @Test
    fun `a private chat request without a peer goes nowhere, as upstream`() {
        // MainActivity.handleNotificationIntent opens nothing when the peer ID is missing.
        listOf(null, "", "  ").forEach { peerID ->
            val navigation = parse(
                NotificationManager.EXTRA_OPEN_PRIVATE_CHAT to true,
                NotificationManager.EXTRA_PEER_ID to peerID,
                NotificationManager.EXTRA_OPEN_MESH_CHAT to true
            )

            assertNull("peer '$peerID'", navigation)
        }
    }

    @Test
    fun `a mesh mention notification opens the public chat`() {
        assertEquals(AppNavigation.PublicChat, parse(NotificationManager.EXTRA_OPEN_MESH_CHAT to true))
    }

    @Test
    fun `a private chat request wins over the public chat, as upstream checks it first`() {
        val navigation = parse(
            NotificationManager.EXTRA_OPEN_PRIVATE_CHAT to true,
            NotificationManager.EXTRA_PEER_ID to ALICE,
            NotificationManager.EXTRA_OPEN_MESH_CHAT to true
        )

        assertEquals(AppNavigation.PrivateChat(ALICE, null), navigation)
    }

    @Test
    fun `other intents only bring the app to the front`() {
        // Launcher, the mesh service's own notification, summary notifications: no extras.
        assertNull(parse())
        // Geohash chats have no Flutter screen (P3; Nostr is off, so none arrive either).
        assertNull(
            parse(
                NotificationManager.EXTRA_OPEN_GEOHASH_CHAT to true,
                NotificationManager.EXTRA_GEOHASH to "u4pruyd"
            )
        )
    }

    @Test
    fun `reopening from recents does not replay the notification that started the task`() {
        // The task's base intent is still the notification's; Android flags the relaunch.
        val navigation = parse(
            NotificationManager.EXTRA_OPEN_PRIVATE_CHAT to true,
            NotificationManager.EXTRA_PEER_ID to ALICE,
            launchedFromHistory = true
        )

        assertNull(navigation)
    }

    // --- what MainActivity.handleNotificationIntent does besides opening the chat ------------

    @Test
    fun `a private chat request clears that sender's notifications`() {
        val viewModel = mock<ChatViewModel>()

        AppNavigation.PrivateChat(ALICE, "alice").clearNotifications(viewModel)

        verify(viewModel).clearNotificationsForSender(ALICE)
        verify(viewModel, never()).clearMeshMentionNotifications()
    }

    @Test
    fun `a public chat request clears the mention notifications`() {
        val viewModel = mock<ChatViewModel>()

        AppNavigation.PublicChat.clearNotifications(viewModel)

        verify(viewModel).clearMeshMentionNotifications()
        verifyNoMoreInteractions(viewModel)
    }

    // --- the request waiting for Dart --------------------------------------------------------

    @Test
    fun `nothing is pending at first`() {
        val pending = PendingAppNavigation()

        assertNull(pending.pending.value)
        assertNull(pending.take())
    }

    @Test
    fun `a request is taken exactly once`() {
        val pending = PendingAppNavigation()
        pending.offer(AppNavigation.PrivateChat(ALICE, "alice"))

        assertEquals(AppNavigation.PrivateChat(ALICE, "alice"), pending.pending.value)
        assertEquals(AppNavigation.PrivateChat(ALICE, "alice"), pending.take())
        assertNull(pending.pending.value)
        assertNull(pending.take())
    }

    @Test
    fun `the latest tap wins over one Dart has not taken yet`() {
        val pending = PendingAppNavigation()
        pending.offer(AppNavigation.PrivateChat(ALICE, "alice"))

        pending.offer(AppNavigation.PublicChat)

        assertEquals(AppNavigation.PublicChat, pending.take())
        assertNull(pending.take())
    }

    // --- wire format -------------------------------------------------------------------------

    @Test
    fun `navigation maps carry the target and upstream's extras`() {
        assertEquals(
            mapOf("target" to "privateChat", "peerID" to ALICE, "senderNickname" to "alice"),
            ChatSerialization.navigation(AppNavigation.PrivateChat(ALICE, "alice"))
        )
        assertEquals(
            mapOf("target" to "privateChat", "peerID" to ALICE, "senderNickname" to null),
            ChatSerialization.navigation(AppNavigation.PrivateChat(ALICE, null))
        )
        assertEquals(mapOf("target" to "publicChat"), ChatSerialization.navigation(AppNavigation.PublicChat))
        assertNull(ChatSerialization.navigation(null))
    }

    @Test
    fun `the pending navigation event wraps the request, null when none`() {
        assertEquals(
            mapOf("type" to "chat_pending_navigation", "navigation" to mapOf("target" to "publicChat")),
            ChatSerialization.pendingNavigationEvent(AppNavigation.PublicChat)
        )
        assertEquals(
            mapOf("type" to "chat_pending_navigation", "navigation" to null),
            ChatSerialization.pendingNavigationEvent(null)
        )
    }

    private fun parse(vararg extras: Pair<String, Any?>, launchedFromHistory: Boolean = false): AppNavigation? {
        val values = extras.toMap()
        return AppNavigation.fromNotification(
            launchedFromHistory = launchedFromHistory,
            flag = { values[it] as? Boolean ?: false },
            text = { values[it] as? String }
        )
    }

    private companion object {
        const val ALICE = "1111111111111111"
        val CONTACT = "contact_" + "a".repeat(64)
    }
}
