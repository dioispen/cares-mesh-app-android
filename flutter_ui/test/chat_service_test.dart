import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/chat_service.dart';

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
    Future<bool> Function(String text)? sendMessage,
    Future<void> Function(String nickname)? setNickname,
  }) =>
      ChatService(
        events: () => events.stream,
        requestSnapshot: requestSnapshot ??
            () async {
              calls.add('requestSnapshot(listening: ${events.hasListener})');
            },
        sendMessage: sendMessage ??
            (text) async {
              calls.add('send:$text');
              return true;
            },
        setNickname: setNickname ??
            (nickname) async {
              calls.add('setNickname:$nickname');
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
    service = buildService(sendMessage: (text) async {
      calls.add('send:$text');
      return false;
    });

    final accepted = await service.sendMessage('  hello  ');

    expect(accepted, isFalse);
    expect(calls, ['send:  hello  ']);
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
}
