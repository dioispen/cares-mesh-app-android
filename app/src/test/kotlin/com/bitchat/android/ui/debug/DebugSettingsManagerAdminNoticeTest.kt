package com.bitchat.android.ui.debug

import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The debug screen counts incoming packets per link and per sending peer. An Admin Notice (0x31)
 * did come in over a link, but its senderID is a messageId, not a peer (ADR-0011, #137).
 */
class DebugSettingsManagerAdminNoticeTest {
    private val debug = DebugSettingsManager.getInstance()

    @Test
    fun `an incoming Admin Notice counts for its link but not as a peer`() {
        val messageId = "a1b2c3d4e5f60718"
        val link = "AA:00:00:00:31:01"
        val before = debug.perDeviceIncomingTotal.value[link] ?: 0L

        debug.logIncoming(
            packet = BitchatPacket(
                version = 1u,
                type = MessageType.ADMIN_NOTICE.value,
                senderID = ByteArray(8) { i -> messageId.substring(i * 2, i * 2 + 2).toInt(16).toByte() },
                recipientID = null,
                timestamp = 1_792_627_200_000uL,
                payload = ByteArray(120),
                ttl = 6u
            ),
            fromPeerID = messageId,
            fromNickname = null,
            fromDeviceAddress = link,
            myPeerID = "1111222233334444"
        )

        assertEquals(before + 1, debug.perDeviceIncomingTotal.value[link])
        assertFalse(debug.perPeerIncomingTotal.value.containsKey(messageId))
    }
}
