/// 輸入框 `/` 指令補完與 `@` 提及補完的 Dart 端模型（#54）。
///
/// 欄位與 Kotlin `ChatSerialization.suggestionsEvent` / `commandSuggestion`
/// （`app/src/main/java/com/bitchat/android/flutter/ChatSerialization.kt`）一一對應，兩邊要一起改。
/// 補完清單由原生 `ChatViewModel`（上游 `CommandProcessor`）依輸入文字產生：有哪些指令、
/// 怎麼篩選排序、哪些暱稱可以提及，都照原生；這裡只把 map 轉成型別，不重新推導。
///
/// 解析一律容錯、永遠不丟例外：單一項目不對時略過或用預設值；整份快照的外框
/// （兩個旗標與兩個清單）不對時整份拒收，讓呼叫端保留現有狀態。
library;

/// 一個 `/` 指令補完，欄位與上游 `CommandSuggestion` 相同。
///
/// 選取時只把 [command] 交回原生端，由原生端從它目前提供的清單找回上游物件；
/// Dart 不自組 `CommandSuggestion` 內容。
class CommandSuggestion {
  const CommandSuggestion({
    required this.command,
    this.aliases = const [],
    this.syntax,
    required this.description,
  });

  /// 例如 `/m`。
  final String command;

  /// 例如 `['/msg']`；沒有別名時是空清單。
  final List<String> aliases;

  /// 參數說明，例如 `<nickname> [message]`；沒有參數的指令是 null。
  final String? syntax;

  /// 上游的說明文字（原文，未翻譯）。
  final String description;

  /// 原生清單顯示的名稱：指令與別名以「, 」相接，例如 `/j, /join`。
  String get label => [command, ...aliases].join(', ');

  /// 不是 Map、或沒有非空字串的 `command` 時回傳 null。
  static CommandSuggestion? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final command = raw['command'];
    if (command is! String || command.isEmpty) return null;
    final aliases = raw['aliases'];
    final syntax = raw['syntax'];
    final description = raw['description'];
    return CommandSuggestion(
      command: command,
      aliases: aliases is List ? List.unmodifiable(aliases.whereType<String>()) : const [],
      syntax: syntax is String ? syntax : null,
      description: description is String ? description : '',
    );
  }
}

/// 一份 `chat_suggestions` 快照：原生 `ChatViewModel` 的四個補完狀態，原樣。
class ChatSuggestions {
  const ChatSuggestions({
    this.showCommands = false,
    this.commands = const [],
    this.showMentions = false,
    this.mentions = const [],
  });

  /// 什麼都不顯示（原生端還沒回報，或補完已關閉）。
  static const none = ChatSuggestions();

  final bool showCommands;

  /// 依原生順序（上游已依指令名稱排序）；不可修改。
  final List<CommandSuggestion> commands;

  final bool showMentions;

  /// 可提及的線上暱稱，依原生順序（上游已篩選、去重、排序）；不可修改。
  final List<String> mentions;

  /// 原生輸入框顯示指令清單的條件：旗標打開且清單不是空的。
  bool get commandsVisible => showCommands && commands.isNotEmpty;

  /// 原生輸入框顯示提及清單的條件：旗標打開且清單不是空的。
  bool get mentionsVisible => showMentions && mentions.isNotEmpty;

  /// 解析 `{type: chat_suggestions, showCommands, commands, showMentions, mentions}`。
  /// 兩個旗標不是 bool、或兩個清單不是 List 時回傳 null；清單中不對的項目略過、保留其餘順序。
  static ChatSuggestions? fromEvent(Map<String, dynamic> event) {
    final showCommands = event['showCommands'];
    final commands = event['commands'];
    final showMentions = event['showMentions'];
    final mentions = event['mentions'];
    if (showCommands is! bool || commands is! List || showMentions is! bool || mentions is! List) {
      return null;
    }
    return ChatSuggestions(
      showCommands: showCommands,
      commands: List.unmodifiable([
        for (final entry in commands) ?CommandSuggestion.fromMap(entry),
      ]),
      showMentions: showMentions,
      mentions: List.unmodifiable(mentions.whereType<String>()),
    );
  }
}
