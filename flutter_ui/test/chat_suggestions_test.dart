import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_suggestions.dart';

/// 與 Kotlin `ChatSerialization.suggestionsEvent` 輸出同形（見 ChatSerializationTest）。
Map<String, dynamic> _event({
  Object? showCommands = true,
  Object? commands,
  Object? showMentions = false,
  Object? mentions = const <String>[],
}) =>
    {
      'type': 'chat_suggestions',
      'showCommands': showCommands,
      'commands': commands ??
          [
            {
              'command': '/j',
              'aliases': ['/join'],
              'syntax': '<channel>',
              'description': 'join or create a channel',
            },
            {'command': '/w', 'aliases': <String>[], 'syntax': null, 'description': "see who's online"},
          ],
      'showMentions': showMentions,
      'mentions': mentions,
    };

void main() {
  group('ChatSuggestions.fromEvent', () {
    test('parses both popups in the order Kotlin sends', () {
      final s = ChatSuggestions.fromEvent(_event(showMentions: true, mentions: ['bob', 'alice']))!;

      expect(s.showCommands, isTrue);
      expect(s.commands.map((c) => c.command), ['/j', '/w']);
      expect(s.showMentions, isTrue);
      expect(s.mentions, ['bob', 'alice']);
    });

    test('parses every command suggestion field', () {
      final j = ChatSuggestions.fromEvent(_event())!.commands.first;

      expect(j.command, '/j');
      expect(j.aliases, ['/join']);
      expect(j.syntax, '<channel>');
      expect(j.description, 'join or create a channel');
    });

    test('a command without syntax or aliases keeps null and an empty list', () {
      final w = ChatSuggestions.fromEvent(_event())!.commands.last;

      expect(w.syntax, isNull);
      expect(w.aliases, isEmpty);
    });

    test('a popup is visible only when its flag is set and its list is not empty, as natively', () {
      expect(ChatSuggestions.fromEvent(_event(showCommands: true))!.commandsVisible, isTrue);
      expect(ChatSuggestions.fromEvent(_event(showCommands: false))!.commandsVisible, isFalse);
      expect(ChatSuggestions.fromEvent(_event(showCommands: true, commands: []))!.commandsVisible, isFalse);
      expect(ChatSuggestions.fromEvent(_event(showMentions: true, mentions: ['bob']))!.mentionsVisible, isTrue);
      expect(ChatSuggestions.fromEvent(_event(showMentions: false, mentions: ['bob']))!.mentionsVisible, isFalse);
      expect(ChatSuggestions.fromEvent(_event(showMentions: true, mentions: []))!.mentionsVisible, isFalse);
    });

    test('accepts the Map<Object?, Object?> shape the codec actually delivers', () {
      final s = ChatSuggestions.fromEvent(_event(commands: [
        <Object?, Object?>{'command': '/hug', 'aliases': <Object?>[], 'syntax': '<nickname>', 'description': 'hug'},
      ]))!;

      expect(s.commands.single.command, '/hug');
    });

    test('skips command entries without a command and keeps the rest', () {
      final s = ChatSuggestions.fromEvent(_event(commands: [
        {'command': '/clear', 'description': 'clear chat messages'},
        {'command': '', 'description': 'blank'},
        {'description': 'no command'},
        'garbage',
        null,
      ]))!;

      expect(s.commands.map((c) => c.command), ['/clear']);
    });

    test('mistyped command fields fall back to defaults', () {
      final c = ChatSuggestions.fromEvent(_event(commands: [
        {'command': '/m', 'aliases': ['/msg', 3, null], 'syntax': 42, 'description': null},
      ]))!.commands.single;

      expect(c.aliases, ['/msg']);
      expect(c.syntax, isNull);
      expect(c.description, '');
    });

    test('keeps only the string nicknames', () {
      final s = ChatSuggestions.fromEvent(_event(showMentions: true, mentions: ['bob', 1, null, '小明']))!;

      expect(s.mentions, ['bob', '小明']);
    });

    test('a malformed frame is rejected as a whole', () {
      expect(ChatSuggestions.fromEvent({'type': 'chat_suggestions'}), isNull);
      expect(ChatSuggestions.fromEvent(_event(showCommands: 'yes')), isNull);
      expect(ChatSuggestions.fromEvent(_event(commands: 'nope')), isNull);
      expect(ChatSuggestions.fromEvent(_event(showMentions: null)), isNull);
      expect(ChatSuggestions.fromEvent(_event(mentions: 'bob')), isNull);
    });

    test('the lists cannot be mutated by readers', () {
      final s = ChatSuggestions.fromEvent(_event(showMentions: true, mentions: ['bob']))!;

      expect(() => s.commands.clear(), throwsUnsupportedError);
      expect(() => s.mentions.clear(), throwsUnsupportedError);
      expect(() => s.commands.first.aliases.clear(), throwsUnsupportedError);
    });
  });

  test('none shows nothing', () {
    expect(ChatSuggestions.none.commandsVisible, isFalse);
    expect(ChatSuggestions.none.mentionsVisible, isFalse);
  });

  test('a command is labelled with its aliases, as the native list shows it', () {
    const j = CommandSuggestion(command: '/j', aliases: ['/join'], description: '');
    const w = CommandSuggestion(command: '/w', description: '');

    expect(j.label, '/j, /join');
    expect(w.label, '/w');
  });
}
