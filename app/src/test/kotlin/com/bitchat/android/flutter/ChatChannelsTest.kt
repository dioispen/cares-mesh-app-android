package com.bitchat.android.flutter

import com.bitchat.android.ui.CommandSuggestion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatChannelsTest {

    @Test
    fun `the join command and its alias are recognised as upstream reads them`() {
        listOf("/j #help", "/j help secret", "/join #help", "/J #help", "/JOIN", "/j", "/join").forEach { text ->
            assertTrue(text, ChatChannels.isJoinCommand(text))
        }
    }

    @Test
    fun `anything else is not the join command`() {
        // Upstream splits on single spaces: "/j\t#x" is its unknown command "/j\t#x", not a join.
        listOf("/joinx", "/jump", "/m alice hi", "j #help", "hello /j #help", "", "/j\t#help").forEach { text ->
            assertFalse(text, ChatChannels.isJoinCommand(text))
        }
    }

    @Test
    fun `every suggestion upstream offers is offered, except the channel commands`() {
        val suggestions = listOf(
            CommandSuggestion("/block", emptyList(), "[nickname]", "block or list blocked peers"),
            CommandSuggestion("/channels", emptyList(), null, "show all discovered channels"),
            CommandSuggestion("/j", listOf("/join"), "<channel>", "join or create a channel"),
            CommandSuggestion("/m", listOf("/msg"), "<nickname> [message]", "send private message"),
            CommandSuggestion("/join", emptyList(), "<channel>", "an alias listed on its own")
        )

        assertEquals(listOf("/block", "/m"), suggestions.filter(ChatChannels::isOffered).map { it.command })
    }

    @Test
    fun `channels is not the join command, so typing it still reaches upstream`() {
        assertFalse(ChatChannels.isJoinCommand("/channels"))
    }
}
