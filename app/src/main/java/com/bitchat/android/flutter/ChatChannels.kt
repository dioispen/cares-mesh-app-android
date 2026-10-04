package com.bitchat.android.flutter

import com.bitchat.android.ui.CommandSuggestion

/**
 * Upstream's `#channels`, which the Flutter chat does not support yet (P3, #49 Out of Scope).
 *
 * Joining one is not harmless: `/j #name` (`CommandProcessor` → `ChannelManager.joinChannel`)
 * sets `ChatViewModel.currentChannel`, and from then on upstream sends every public line to that
 * channel instead of the main timeline (`ChatViewModel.sendMessage`). The bridge projects only the
 * main timeline and Dart has no way to leave a channel, so the user's own lines would vanish and
 * nobody on the main timeline would get them. So the Flutter chat never joins one:
 * - the join command is not offered ([isOffered]) and not handed to upstream when typed
 *   ([isJoinCommand]; `chat_sendMessage` refuses it with `CHANNELS_UNSUPPORTED`);
 * - a channel upstream is already in (joined before this rule, or by another writer) is left the
 *   way upstream's own back navigation leaves it, `switchToChannel(null)`, once no private chat is
 *   in focus. That keeps the joined channels and their messages: upstream persists the joined set
 *   in `bitchat_prefs` but not `currentChannel`, which starts null with every ChatViewModel.
 *
 * No other command enters a channel in this upstream version: `/channels` only lists the joined
 * ones; `/pass`, `/save` and `/transfer` work inside a channel and are offered only there; there is
 * no `/leave`. `/channels` is still handed to upstream when typed, but not offered either, so the
 * composer does not suggest a channel feature the Flutter chat lacks.
 */
object ChatChannels {

    /** Upstream's join command and its alias, as `CommandProcessor.processCommand` matches them. */
    val JOIN_COMMANDS: Set<String> = setOf("/j", "/join")

    /** Commands the composer never offers: the join command, and `/channels`, which only lists them. */
    private val NOT_OFFERED: Set<String> = JOIN_COMMANDS + "/channels"

    /**
     * Whether upstream would run [text] (the text it is handed, already trimmed) as its join
     * command: the first space-separated word, lowercased, as `CommandProcessor` reads it.
     */
    fun isJoinCommand(text: String): Boolean =
        text.startsWith("/") && text.split(" ").first().lowercase() in JOIN_COMMANDS

    /** Whether the composer may offer [suggestion]: any upstream offers, except the channel commands. */
    fun isOffered(suggestion: CommandSuggestion): Boolean =
        suggestion.command !in NOT_OFFERED && suggestion.aliases.none { it in NOT_OFFERED }
}
