package com.bitchat.android.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MeshNotificationRepostTest {

    private val showing = MeshNotificationState(
        inForeground = true,
        backgroundEnabled = true,
        hasPermissions = true,
        shuttingDown = false,
        autoRestore = true
    )

    @Test
    fun `a dismissed notification comes back at once when auto-restore is on`() {
        assertTrue(shouldRepostMeshNotification(RepostTrigger.DISMISSED, showing))
    }

    @Test
    fun `a dismissed notification stays dismissed when auto-restore is off`() {
        assertFalse(shouldRepostMeshNotification(RepostTrigger.DISMISSED, showing.copy(autoRestore = false)))
    }

    @Test
    fun `a settings change reposts whether auto-restore is on or off`() {
        assertTrue(shouldRepostMeshNotification(RepostTrigger.SETTING_CHANGED, showing))
        assertTrue(shouldRepostMeshNotification(RepostTrigger.SETTING_CHANGED, showing.copy(autoRestore = false)))
    }

    @Test
    fun `coming back to the app reposts the notification whether auto-restore is on or off`() {
        assertTrue(shouldRepostMeshNotification(RepostTrigger.APP_FOREGROUNDED, showing))
        assertTrue(shouldRepostMeshNotification(RepostTrigger.APP_FOREGROUNDED, showing.copy(autoRestore = false)))
    }

    @Test
    fun `nothing is reposted unless the service is showing its notification`() {
        val notShowing = listOf(
            showing.copy(inForeground = false),
            showing.copy(backgroundEnabled = false),
            showing.copy(hasPermissions = false),
            showing.copy(shuttingDown = true)
        )
        for (state in notShowing) {
            for (trigger in RepostTrigger.values()) {
                assertFalse("$trigger with $state", shouldRepostMeshNotification(trigger, state))
            }
        }
    }
}
