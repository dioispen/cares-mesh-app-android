import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_suggestions.dart';
import 'package:flutter_ui/services/chat_service.dart';

/// A `chat_selected_private_peer` map as Kotlin sends it; [peerID] null means no private chat.
Map<String, dynamic> _focusEvent(String? peerID, {String? name, String draft = ''}) => {
      'type': 'chat_selected_private_peer',
      'peerID': peerID,
      'conversationID': peerID,
      'displayName': peerID == null ? null : (name ?? peerID),
      'draft': peerID == null ? null : draft,
    };

Map<String, dynamic> _publicMessages(List<String> ids) => {
      'type': 'chat_public_messages',
      'messages': [
        for (final id in ids)
          {'id': id, 'sender': 'alice', 'content': 'content of $id', 'timestamp': 1700000000000},
      ],
    };

void main() {
  late StreamController<Map<String, dynamic>> events;
  late List<String> calls;
  late ChatService service;

  ChatService buildService({
    Future<void> Function()? requestSnapshot,
    Future<bool> Function(String text, String? privateChat)? sendMessage,
    Future<void> Function(String nickname)? setNickname,
    Future<String?> Function(String command)? selectCommandSuggestion,
    Future<String> Function(String nickname, String currentText)? selectMentionSuggestion,
    Future<Object?> Function(String peerID)? startPrivateChat,
    Future<Object?> Function()? endPrivateChat,
  }) =>
      ChatService(
        events: () => events.stream,
        requestSnapshot: requestSnapshot ??
            () async {
              calls.add('requestSnapshot(listening: ${events.hasListener})');
            },
        sendMessage: sendMessage ??
            (text, privateChat) async {
              calls.add(privateChat == null ? 'send:$text' : 'send[$privateChat]:$text');
              return true;
            },
        setNickname: setNickname ??
            (nickname) async {
              calls.add('setNickname:$nickname');
            },
        updateInput: (text, privateChat) async {
          calls.add(privateChat == null ? 'updateInput:$text' : 'updateInput[$privateChat]:$text');
        },
        startPrivateChat: startPrivateChat ??
            (peerID) async {
              calls.add('start:$peerID');
              return _focusEvent(peerID);
            },
        endPrivateChat: endPrivateChat ??
            () async {
              calls.add('end');
              return _focusEvent(null);
            },
        selectCommandSuggestion: selectCommandSuggestion ??
            (command) async {
              calls.add('selectCommand:$command');
              return '$command ';
            },
        selectMentionSuggestion: selectMentionSuggestion ??
            (nickname, currentText) async {
              calls.add('selectMention:$nickname|$currentText');
              return '@$nickname ';
            },
        clearSuggestions: () async {
          calls.add('clearSuggestions');
        },
      );

  setUp(() {
    events = StreamController<Map<String, dynamic>>.broadcast();
    calls = [];
    service = buildService();
  });

  tearDown(() async {
    await service.dispose();
    await events.close();
  });

  test('starts with an empty public timeline', () {
    expect(service.publicMessages.value, isEmpty);
  });

  test('start subscribes before asking Kotlin to re-push its snapshots', () async {
    await service.start();

    expect(calls, ['requestSnapshot(listening: true)']);
  });

  test('start is idempotent', () async {
    await service.start();
    await service.start();

    expect(calls, hasLength(1));
  });

  test('a public messages snapshot replaces the whole timeline', () async {
    await service.start();

    events.add(_publicMessages(['A', 'B']));
    await pumpEventQueue();
    expect(service.publicMessages.value.map((m) => m.id), ['A', 'B']);

    events.add(_publicMessages(['B', 'C', 'D']));
    await pumpEventQueue();
    expect(service.publicMessages.value.map((m) => m.id), ['B', 'C', 'D']);
  });

  test('messages received while no screen is open are kept', () async {
    await service.start();
    events.add(_publicMessages(['A']));
    await pumpEventQueue();

    // A screen that opens later just reads the current value.
    expect(service.publicMessages.value.single.content, 'content of A');
  });

  test('listeners are notified on every snapshot', () async {
    var notified = 0;
    service.publicMessages.addListener(() => notified++);
    await service.start();

    events.add(_publicMessages(['A']));
    events.add(_publicMessages(['A', 'B']));
    await pumpEventQueue();

    expect(notified, 2);
  });

  test('a snapshot with a malformed payload keeps the current timeline', () async {
    await service.start();
    events.add(_publicMessages(['A']));
    await pumpEventQueue();

    events.add({'type': 'chat_public_messages'});
    events.add({'type': 'chat_public_messages', 'messages': 'nope'});
    await pumpEventQueue();

    expect(service.publicMessages.value.map((m) => m.id), ['A']);
  });

  test('events of other types are ignored', () async {
    await service.start();

    events.add({'type': 'system_status', 'bluetoothEnabled': true});
    events.add({'type': 'packet', 'payload': [1, 2, 3]});
    events.add({'type': 'chat_something_new', 'messages': []});
    await pumpEventQueue();

    expect(service.publicMessages.value, isEmpty);
  });

  test('the timeline cannot be mutated by readers', () async {
    await service.start();
    events.add(_publicMessages(['A']));
    await pumpEventQueue();

    expect(() => service.publicMessages.value.clear(), throwsUnsupportedError);
  });

  test('a failing snapshot request does not break start', () async {
    service = buildService(requestSnapshot: () async {
      throw MissingPluginException('no native side');
    });

    await service.start();
    events.add(_publicMessages(['A']));
    await pumpEventQueue();

    expect(service.publicMessages.value.map((m) => m.id), ['A']);
  });

  test('an error on the event stream does not stop later snapshots', () async {
    await service.start();

    events.addError(PlatformException(code: 'boom'));
    events.add(_publicMessages(['A']));
    await pumpEventQueue();

    expect(service.publicMessages.value.map((m) => m.id), ['A']);
  });

  test('sendMessage hands the text to the bridge and returns its answer', () async {
    service = buildService(sendMessage: (text, privateChat) async {
      calls.add('send:$text');
      return false;
    });

    final accepted = await service.sendMessage('  hello  ');

    expect(accepted, isFalse);
    expect(calls, ['send:  hello  ']);
  });

  group('private chats (#55)', () {
    const contact = 'contact_aaaa';

    Map<String, dynamic> privateChats(Map<String, List<String>> ids) => {
          'type': 'chat_private_chats',
          'chats': {
            for (final entry in ids.entries)
              entry.key: [
                for (final id in entry.value)
                  {'id': id, 'sender': 'alice', 'content': 'content of $id', 'timestamp': 1700000000000},
              ],
          },
        };

    test('no private chat is selected until Kotlin reports one', () {
      expect(service.selectedPrivateChat.value, isNull);
      expect(service.privateChats.value, isEmpty);
    });

    test('a selection snapshot sets the private chat, and a null one clears it', () async {
      await service.start();

      events.add(_focusEvent(contact, name: 'alice', draft: 'hel'));
      await pumpEventQueue();
      final focus = service.selectedPrivateChat.value!;
      expect([focus.peerID, focus.displayName, focus.draft], [contact, 'alice', 'hel']);

      events.add(_focusEvent(null));
      await pumpEventQueue();
      expect(service.selectedPrivateChat.value, isNull);
    });

    test('a malformed selection snapshot keeps the current private chat', () async {
      await service.start();
      events.add(_focusEvent(contact));
      await pumpEventQueue();

      events.add({'type': 'chat_selected_private_peer', 'peerID': 42});
      events.add({'type': 'chat_selected_private_peer', 'peerID': ''});
      await pumpEventQueue();

      expect(service.selectedPrivateChat.value?.peerID, contact);
    });

    test('startPrivateChat asks Kotlin and takes the private chat it answers with', () async {
      // Kotlin re-keys the tapped mesh peer to its contact conversation.
      service = buildService(startPrivateChat: (peerID) async {
        calls.add('start:$peerID');
        return _focusEvent(contact, name: 'alice');
      });

      await service.startPrivateChat('1111111111111111');

      expect(calls, ['start:1111111111111111']);
      expect(service.selectedPrivateChat.value?.peerID, contact);
    });

    test('a start Kotlin refuses leaves no private chat selected', () async {
      service = buildService(startPrivateChat: (peerID) async => _focusEvent(null));

      await service.startPrivateChat('1111111111111111');

      expect(service.selectedPrivateChat.value, isNull);
    });

    test('endPrivateChat takes Kotlin\'s answer at once, without waiting for the snapshot', () async {
      await service.start();
      events.add(_focusEvent(contact));
      await pumpEventQueue();

      await service.endPrivateChat();

      expect(calls.last, 'end');
      expect(service.selectedPrivateChat.value, isNull);
    });

    test('bridge errors from starting or ending a private chat are surfaced', () async {
      service = buildService(
        startPrivateChat: (peerID) async => throw PlatformException(code: 'PRIVATE_CHAT_FAILED'),
        endPrivateChat: () async => throw MissingPluginException('no native side'),
      );

      await expectLater(service.startPrivateChat('1111111111111111'), throwsA(isA<PlatformException>()));
      await expectLater(service.endPrivateChat(), throwsA(isA<MissingPluginException>()));
    });

    test('a private chats snapshot replaces every conversation', () async {
      await service.start();

      events.add(privateChats({contact: ['P1', 'P2']}));
      await pumpEventQueue();
      expect(service.privateChats.value[contact]!.map((m) => m.id), ['P1', 'P2']);

      events.add(privateChats({'2222222222222222': ['P3']}));
      await pumpEventQueue();
      expect(service.privateChats.value.keys, ['2222222222222222']);
    });

    test('a malformed private chats snapshot keeps the current conversations', () async {
      await service.start();
      events.add(privateChats({contact: ['P1']}));
      await pumpEventQueue();

      events.add({'type': 'chat_private_chats'});
      events.add({'type': 'chat_private_chats', 'chats': 'nope'});
      await pumpEventQueue();

      expect(service.privateChats.value[contact]!.single.id, 'P1');
    });

    test('text and edits from a private chat composer name that private chat', () async {
      await service.sendMessage('see you', privateChat: contact);
      await service.updateInput('see y', privateChat: contact);

      expect(calls, ['send[$contact]:see you', 'updateInput[$contact]:see y']);
    });
  });

  group('mesh nickname', () {
    test('is unknown until Kotlin reports it', () {
      expect(service.nickname.value, isNull);
    });

    test('a nickname snapshot sets it', () async {
      await service.start();

      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});
      await pumpEventQueue();

      expect(service.nickname.value, 'anon4821');
    });

    test('a later snapshot replaces it, whoever changed it upstream', () async {
      await service.start();
      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});
      await pumpEventQueue();

      events.add({'type': 'chat_nickname', 'nickname': 'anon1234'});
      await pumpEventQueue();

      expect(service.nickname.value, 'anon1234');
    });

    test('is kept exactly as upstream holds it, blank included', () async {
      await service.start();

      for (final nickname in ['', ' bob ', '小明']) {
        events.add({'type': 'chat_nickname', 'nickname': nickname});
        await pumpEventQueue();
        expect(service.nickname.value, nickname);
      }
    });

    test('a malformed nickname snapshot keeps the current nickname', () async {
      await service.start();
      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});
      await pumpEventQueue();

      events.add({'type': 'chat_nickname'});
      events.add({'type': 'chat_nickname', 'nickname': 42});
      events.add({'type': 'chat_nickname', 'nickname': null});
      await pumpEventQueue();

      expect(service.nickname.value, 'anon4821');
    });

    test('nickname and timeline snapshots do not disturb each other', () async {
      await service.start();

      events.add(_publicMessages(['A']));
      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});
      await pumpEventQueue();

      expect(service.publicMessages.value.map((m) => m.id), ['A']);
      expect(service.nickname.value, 'anon4821');
    });

    test('setNickname hands the nickname to the bridge untouched', () async {
      await service.setNickname('  bob  ');
      await service.setNickname('');

      expect(calls, ['setNickname:  bob  ', 'setNickname:']);
    });

    test('setNickname waits for Kotlin to report the new nickname', () async {
      await service.start();
      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});
      await pumpEventQueue();

      await service.setNickname('bob');
      expect(service.nickname.value, 'anon4821');

      events.add({'type': 'chat_nickname', 'nickname': 'bob'});
      await pumpEventQueue();
      expect(service.nickname.value, 'bob');
    });

    test('a missing native side is surfaced, not turned into a quiet failure', () async {
      service = buildService(setNickname: (nickname) async {
        throw MissingPluginException('no native side');
      });

      await expectLater(service.setNickname('bob'), throwsA(isA<MissingPluginException>()));
    });

    test('a bridge error from setNickname is surfaced', () async {
      service = buildService(setNickname: (nickname) async {
        throw PlatformException(code: 'INVALID_ARGUMENT');
      });

      await expectLater(service.setNickname('bob'), throwsA(isA<PlatformException>()));
    });
  });

  group('mesh peers', () {
    Map<String, dynamic> peers(int onlineCount, List<String> ids) => {
          'type': 'chat_peers',
          'onlineCount': onlineCount,
          'peers': [
            for (final id in ids)
              {
                'peerID': id,
                'nickname': 'nick-$id',
                'displayName': 'nick-$id',
                'displaySuffix': '',
                'rssi': -60,
                'signalBars': 2,
                'connection': 'bluetooth',
              },
          ],
        };

    test('are unknown until Kotlin reports them', () {
      expect(service.peerList.value, isNull);
    });

    test('a peers snapshot sets the count and the list', () async {
      await service.start();

      events.add(peers(2, ['A', 'B']));
      await pumpEventQueue();

      expect(service.peerList.value!.onlineCount, 2);
      expect(service.peerList.value!.peers.map((p) => p.peerID), ['A', 'B']);
    });

    test('peers joining and leaving replace the whole list', () async {
      await service.start();
      events.add(peers(1, ['A']));
      await pumpEventQueue();

      events.add(peers(2, ['A', 'B']));
      await pumpEventQueue();
      expect(service.peerList.value!.onlineCount, 2);

      events.add(peers(1, ['B']));
      await pumpEventQueue();
      expect(service.peerList.value!.onlineCount, 1);
      expect(service.peerList.value!.peers.map((p) => p.peerID), ['B']);

      events.add(peers(0, []));
      await pumpEventQueue();
      expect(service.peerList.value!.onlineCount, 0);
      expect(service.peerList.value!.peers, isEmpty);
    });

    test('count and list change together, in one notification', () async {
      final seen = <String>[];
      service.peerList.addListener(() {
        final list = service.peerList.value!;
        seen.add('${list.onlineCount}:${list.peers.length}');
      });
      await service.start();

      events.add(peers(1, ['A']));
      events.add(peers(2, ['A', 'B']));
      await pumpEventQueue();

      expect(seen, ['1:1', '2:2']);
    });

    test('a malformed peers snapshot keeps the current list', () async {
      await service.start();
      events.add(peers(1, ['A']));
      await pumpEventQueue();

      events.add({'type': 'chat_peers'});
      events.add({'type': 'chat_peers', 'onlineCount': 1, 'peers': 'nope'});
      events.add({'type': 'chat_peers', 'onlineCount': 'many', 'peers': []});
      await pumpEventQueue();

      expect(service.peerList.value!.peers.map((p) => p.peerID), ['A']);
    });

    test('peers, nickname and timeline snapshots do not disturb each other', () async {
      await service.start();

      events.add(_publicMessages(['M']));
      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});
      events.add(peers(1, ['A']));
      await pumpEventQueue();

      expect(service.publicMessages.value.map((m) => m.id), ['M']);
      expect(service.nickname.value, 'anon4821');
      expect(service.peerList.value!.peers.map((p) => p.peerID), ['A']);
    });
  });

  group('mention and command suggestions', () {
    Map<String, dynamic> suggestions({
      bool showCommands = false,
      List<String> commands = const [],
      bool showMentions = false,
      List<String> mentions = const [],
    }) =>
        {
          'type': 'chat_suggestions',
          'showCommands': showCommands,
          'commands': [
            for (final c in commands) {'command': c, 'aliases': <String>[], 'syntax': null, 'description': 'd'},
          ],
          'showMentions': showMentions,
          'mentions': mentions,
        };

    test('start with nothing to show', () {
      expect(service.suggestions.value.commandsVisible, isFalse);
      expect(service.suggestions.value.mentionsVisible, isFalse);
    });

    test('a suggestions snapshot replaces both popups', () async {
      await service.start();

      events.add(suggestions(showCommands: true, commands: ['/hug', '/w']));
      await pumpEventQueue();
      expect(service.suggestions.value.commands.map((c) => c.command), ['/hug', '/w']);
      expect(service.suggestions.value.mentionsVisible, isFalse);

      events.add(suggestions(showMentions: true, mentions: ['alice']));
      await pumpEventQueue();
      expect(service.suggestions.value.commandsVisible, isFalse);
      expect(service.suggestions.value.mentions, ['alice']);
    });

    test('a malformed suggestions snapshot keeps the current popups', () async {
      await service.start();
      events.add(suggestions(showMentions: true, mentions: ['alice']));
      await pumpEventQueue();

      events.add({'type': 'chat_suggestions'});
      events.add({...suggestions(), 'mentions': 'bob'});
      await pumpEventQueue();

      expect(service.suggestions.value.mentions, ['alice']);
    });

    test('suggestions and the other snapshots do not disturb each other', () async {
      await service.start();

      events.add(_publicMessages(['M']));
      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});
      events.add(suggestions(showMentions: true, mentions: ['alice']));
      await pumpEventQueue();

      expect(service.publicMessages.value.map((m) => m.id), ['M']);
      expect(service.nickname.value, 'anon4821');
      expect(service.suggestions.value.mentions, ['alice']);
    });

    test('updateInput hands the text to the bridge untouched', () async {
      await service.updateInput('  @al');
      await service.updateInput('');

      expect(calls, ['updateInput:  @al', 'updateInput:']);
    });

    test('selecting a command names it by its command and answers the new input', () async {
      const hug = CommandSuggestion(command: '/hug', syntax: '<nickname>', description: 'hug');

      final text = await service.selectCommandSuggestion(hug);

      expect(calls, ['selectCommand:/hug']);
      expect(text, '/hug ');
    });

    test('a command the native side no longer offers answers null', () async {
      service = buildService(selectCommandSuggestion: (command) async => null);

      expect(await service.selectCommandSuggestion(const CommandSuggestion(command: '/hug', description: '')), isNull);
    });

    test('selecting a mention hands over the nickname and the current text', () async {
      final text = await service.selectMentionSuggestion('alice', 'hi @al');

      expect(calls, ['selectMention:alice|hi @al']);
      expect(text, '@alice ');
    });

    test('clearSuggestions is forwarded', () async {
      await service.clearSuggestions();

      expect(calls, ['clearSuggestions']);
    });

    test('suggestions are not changed locally; they wait for the snapshot', () async {
      await service.start();
      events.add(suggestions(showMentions: true, mentions: ['alice']));
      await pumpEventQueue();

      await service.selectMentionSuggestion('alice', '@al');
      await service.clearSuggestions();

      expect(service.suggestions.value.mentions, ['alice']);
    });

    test('a bridge error from selecting a mention is surfaced', () async {
      service = buildService(selectMentionSuggestion: (nickname, currentText) async {
        throw PlatformException(code: 'INVALID_ARGUMENT');
      });

      await expectLater(service.selectMentionSuggestion('alice', '@al'), throwsA(isA<PlatformException>()));
    });
  });
}
