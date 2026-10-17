import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/chat_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';

/// The chat composer: it makes room for the assistant only while the assistant is shown, and
/// tapping elsewhere in the chat closes the keyboard while sending keeps it open.
void main() {
  late StreamController<Map<String, dynamic>> events;
  late ChatService service;
  late List<String> sent;

  setUp(() async {
    mascotEnabledNotifier.value = true;
    sent = [];
    events = StreamController<Map<String, dynamic>>.broadcast();
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text, privateChat) async {
        sent.add(text);
        return true;
      },
      setNickname: (nickname) async {},
      updateInput: (text, privateChat) async {},
      selectCommandSuggestion: (command) async => '$command ',
      selectMentionSuggestion: (nickname, currentText) async => '@$nickname ',
      clearSuggestions: () async {},
      startPrivateChat: (peerID) async => {'type': 'chat_selected_private_peer', 'peerID': peerID},
      endPrivateChat: () async => {'type': 'chat_selected_private_peer', 'peerID': null},
    );
    await service.start();
  });

  tearDown(() async {
    mascotEnabledNotifier.value = true;
    mascotOptionsNotifier.value = const [];
    await service.dispose();
    await events.close();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [mascotRouteObserver],
      home: ChatScreen(chatService: service),
    ));
    events.add({
      'type': 'chat_public_messages',
      'messages': [
        {
          'id': 'm1',
          'sender': 'alice',
          'content': '附近有沒有人需要飲用水？',
          'timestamp': DateTime(2024, 5, 1, 9, 7).millisecondsSinceEpoch,
          'isFromSelf': false,
        },
      ],
    });
    await tester.pump();
    await tester.pump();
  }

  Finder sendButton() => find.byIcon(Icons.send_rounded);
  bool composerFocused(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  group('room for the assistant', () {
    testWidgets('is kept on the right while the assistant is shown', (tester) async {
      await pumpChat(tester);
      expect(mascotOptionsNotifier.value, isNotEmpty, reason: 'the chat screen offers assistant options');

      expect(tester.getRect(sendButton()).right, lessThan(400 - 90));
    });

    testWidgets('is given back to the composer once the assistant is switched off', (tester) async {
      await pumpChat(tester);

      mascotEnabledNotifier.value = false;
      await tester.pump();

      // The send button's circle ends at the composer's 14 px right padding.
      final circle = find.ancestor(of: sendButton(), matching: find.byType(Container)).first;
      expect(tester.getRect(circle).right, 400 - 14);
    });
  });

  group('the keyboard', () {
    testWidgets('closes when the message list is tapped', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(composerFocused(tester), isTrue);

      await tester.tap(find.text('附近有沒有人需要飲用水？'));
      await tester.pump();

      expect(composerFocused(tester), isFalse);
    });

    testWidgets('stays open when a message is sent', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '收到');
      await tester.pump();

      await tester.tap(sendButton());
      await tester.pump();
      await tester.pump();

      expect(sent, ['收到']);
      expect(composerFocused(tester), isTrue);
    });
  });
}
