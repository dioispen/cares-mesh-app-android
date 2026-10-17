import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/chat_screen.dart';
import 'package:flutter_ui/screens/private_chat_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';

import 'support/screen_sizes.dart';

/// 聊天室、暱稱對話框與私訊畫面在小螢幕、大字體、鍵盤彈出時不會 overflow（#79）。
void main() {
  late StreamController<Map<String, dynamic>> events;
  late ChatService service;

  setUp(() async {
    events = StreamController<Map<String, dynamic>>.broadcast();
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text, privateChat) async => true,
      setNickname: (nickname) async {},
      updateInput: (text, privateChat) async {},
      selectCommandSuggestion: (command) async => '$command ',
      selectMentionSuggestion: (nickname, currentText) async => '@$nickname ',
      clearSuggestions: () async {},
      startPrivateChat: (peerID) async => {
        'type': 'chat_selected_private_peer',
        'peerID': peerID,
        'conversationID': peerID,
        'displayName': '一個很長很長很長很長很長很長的暱稱',
        'draft': '',
      },
      endPrivateChat: () async => {'type': 'chat_selected_private_peer', 'peerID': null},
    );
    await service.start();
  });

  tearDown(() async {
    await service.dispose();
    await events.close();
  });

  Future<void> push(WidgetTester tester, Map<String, dynamic> event) async {
    events.add(event);
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [mascotRouteObserver],
      home: ChatScreen(chatService: service),
    ));
    await push(tester, {'type': 'chat_nickname', 'nickname': 'anon4821'});
    await push(tester, {
      'type': 'chat_public_messages',
      'messages': [
        for (var i = 0; i < 20; i++)
          {
            'id': 'm$i',
            'sender': 'alice',
            'content': '訊息 $i：附近有沒有人需要飲用水或是醫療協助？',
            'timestamp': DateTime(2024, 5, 1, 9, 7).millisecondsSinceEpoch,
            'isFromSelf': false,
          },
      ],
    });
  }

  for (final screen in [...layoutCases, smallPhoneLargeText.withKeyboard()]) {
    testWidgets('the public chat fits on $screen', (tester) async {
      useScreen(tester, screen);

      await pumpChat(tester);

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the full command list above the composer still fits once the keyboard is up', (tester) async {
    useScreen(tester, smallPhoneLargeText);
    await pumpChat(tester);
    await tester.enterText(find.byType(TextField), '/');
    await push(tester, {
      'type': 'chat_suggestions',
      'showCommands': true,
      'commands': [
        for (final c in ['/block', '/channels', '/clear', '/hug', '/j', '/m', '/slap', '/unblock', '/w'])
          {'command': c, 'aliases': <String>[], 'syntax': '<nickname>', 'description': 'what $c does'},
      ],
      'showMentions': false,
      'mentions': <String>[],
    });
    expect(tester.takeException(), isNull);

    setKeyboard(tester, 280);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('/block'), findsOneWidget, reason: 'the list is still shown, it just scrolls');
    // The composer stays above the keyboard.
    final composerBottom = tester.getRect(find.byType(TextField)).bottom;
    expect(composerBottom, lessThanOrEqualTo(smallPhoneLargeText.size.height - 280));
  });

  for (final screen in [...layoutCases, smallPhoneLargeText.withKeyboard()]) {
    testWidgets('the mesh nickname dialog fits on $screen', (tester) async {
      useScreen(tester, screen);
      await pumpChat(tester);

      await tester.tap(find.byTooltip('修改 mesh 暱稱'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  }

  testWidgets('the mesh nickname dialog keeps its buttons reachable with the keyboard up', (tester) async {
    useScreen(tester, smallPhoneLargeText.withKeyboard(320));
    await pumpChat(tester);
    await tester.tap(find.byTooltip('修改 mesh 暱稱'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final save = tester.getRect(find.text('儲存'));
    expect(save.bottom, lessThanOrEqualTo(smallPhoneLargeText.size.height - 320));
  });

  for (final screen in [...layoutCases, smallPhoneLargeText.withKeyboard()]) {
    testWidgets('a private chat fits on $screen', (tester) async {
      useScreen(tester, screen);
      await tester.pumpWidget(MaterialApp(
        home: PrivateChatScreen(peerID: 'contact_aaaa', title: 'alice', chatService: service),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
    });
  }
}
