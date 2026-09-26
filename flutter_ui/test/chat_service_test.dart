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
}
