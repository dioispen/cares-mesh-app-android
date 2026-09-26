import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/chat_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';

void main() {
  late StreamController<Map<String, dynamic>> events;
  late List<String> sent;
  late Future<bool> Function(String text) send;
  late ChatService service;

  setUp(() async {
    events = StreamController<Map<String, dynamic>>.broadcast();
    sent = [];
    send = (text) async {
      sent.add(text);
      return true;
    };
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text) => send(text),
    );
    await service.start();
  });

  tearDown(() async {
    await service.dispose();
    await events.close();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [mascotRouteObserver],
      home: ChatScreen(chatService: service),
    ));
  }

  Future<void> pushTimeline(WidgetTester tester, List<Map<String, Object?>> messages) async {
    events.add({'type': 'chat_public_messages', 'messages': messages});
    await tester.pump();
    await tester.pump();
  }

  Map<String, Object?> message(
    String id, {
    String sender = 'alice',
    String content = 'hello',
    bool isFromSelf = false,
    bool isSystem = false,
  }) =>
      {
        'id': id,
        'sender': sender,
        'content': content,
        'timestamp': DateTime(2024, 5, 1, 9, 7).millisecondsSinceEpoch,
        'isFromSelf': isFromSelf,
        'isSystem': isSystem,
      };

  testWidgets('shows no made-up messages before the mesh has any', (tester) async {
    await pumpChat(tester);

    expect(find.textContaining('志工'), findsNothing);
    expect(find.textContaining('歡迎進入防災互助通訊'), findsNothing);
  });

  testWidgets('shows mesh messages with sender nickname and time', (tester) async {
    await pumpChat(tester);

    await pushTimeline(tester, [message('A', sender: 'alice', content: 'anyone near the station?')]);

    expect(find.text('alice'), findsOneWidget);
    expect(find.text('anyone near the station?'), findsOneWidget);
    expect(find.text('09:07'), findsOneWidget);
  });

  testWidgets('messages that arrived before the screen opened are shown', (tester) async {
    events.add({'type': 'chat_public_messages', 'messages': [message('A', content: 'sent earlier')]});
    await tester.pump();

    await pumpChat(tester);

    expect(find.text('sent earlier'), findsOneWidget);
  });

  testWidgets('own messages carry no sender label', (tester) async {
    await pumpChat(tester);

    await pushTimeline(tester, [message('A', sender: 'me', content: 'my words', isFromSelf: true)]);

    expect(find.text('my words'), findsOneWidget);
    expect(find.text('me'), findsNothing);
  });

  testWidgets('system lines render as a centred notice', (tester) async {
    await pumpChat(tester);

    await pushTimeline(tester, [message('S', sender: 'system', content: 'online: alice', isSystem: true)]);

    expect(find.text('online: alice'), findsOneWidget);
    expect(find.text('system'), findsNothing);
  });

  testWidgets('sending hands the text to ChatService and clears the field once accepted', (tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'hello mesh');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(sent, ['hello mesh']);
    expect(find.text('hello mesh'), findsNothing);
  });

  testWidgets('text the native side refused stays in the field', (tester) async {
    send = (text) async {
      sent.add(text);
      return false;
    };
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'hello mesh');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(sent, ['hello mesh']);
    expect(find.text('hello mesh'), findsOneWidget);
  });

  testWidgets('a failed send keeps the text and tells the user', (tester) async {
    send = (text) async => throw PlatformException(code: 'boom');
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'hello mesh');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(find.text('hello mesh'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('blank input is not sent', (tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(sent, isEmpty);
  });
}
