import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart' show ChatErrors;
import 'package:flutter_ui/screens/private_chat_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/widgets/chat_message_tile.dart' show ChatPalette;
import 'package:flutter_ui/widgets/favorite_star_button.dart';

const _alice = '1111111111111111';
const _contact = 'contact_aaaa';
const _bob = '2222222222222222';

/// A `chat_selected_private_peer` map as Kotlin sends it; [peerID] null means no private chat.
Map<String, dynamic> _focus(
  String? peerID, {
  String? name,
  String? conversationID,
  String draft = '',
  bool isFavorite = false,
  bool theyFavoritedUs = false,
}) =>
    {
      'type': 'chat_selected_private_peer',
      'peerID': peerID,
      'conversationID': peerID == null ? null : (conversationID ?? peerID),
      'displayName': peerID == null ? null : (name ?? peerID),
      'draft': peerID == null ? null : draft,
      'isFavorite': peerID == null ? null : isFavorite,
      'theyFavoritedUs': peerID == null ? null : theyFavoritedUs,
    };

Map<String, Object?> _message(
  String id, {
  String sender = 'alice',
  bool isFromSelf = false,
  Map<String, Object?>? deliveryStatus,
}) =>
    {
      'id': id,
      'sender': sender,
      'content': 'text of $id',
      'timestamp': DateTime(2024, 5, 1, 9, 7).millisecondsSinceEpoch,
      'isPrivate': true,
      'isFromSelf': isFromSelf,
      'deliveryStatus': deliveryStatus,
    };

void main() {
  late StreamController<Map<String, dynamic>> events;
  late List<String> calls;
  late Completer<Object?>? pendingStart;
  late Object? startAnswer;
  late Future<bool> Function(String text, String? privateChat) send;
  late Future<void> Function(String peerID) toggleFavorite;
  late ChatService service;

  setUp(() async {
    events = StreamController<Map<String, dynamic>>.broadcast();
    calls = [];
    pendingStart = null;
    startAnswer = _focus(_contact, name: 'alice');
    send = (text, privateChat) async => true;
    toggleFavorite = (peerID) async {};
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text, privateChat) {
        calls.add('send[$privateChat]:$text');
        return send(text, privateChat);
      },
      setNickname: (nickname) async {},
      updateInput: (text, privateChat) async => calls.add('updateInput[$privateChat]:$text'),
      selectCommandSuggestion: (command) async {
        calls.add('selectCommand:$command');
        return '$command ';
      },
      selectMentionSuggestion: (nickname, currentText) async => '@$nickname ',
      clearSuggestions: () async => calls.add('clearSuggestions'),
      startPrivateChat: (peerID) {
        calls.add('start:$peerID');
        return pendingStart?.future ?? Future.value(startAnswer);
      },
      endPrivateChat: () async {
        calls.add('end');
        return _focus(null);
      },
      toggleFavorite: (peerID) {
        calls.add('toggleFavorite:$peerID');
        return toggleFavorite(peerID);
      },
    );
    await service.start();
  });

  tearDown(() async {
    await service.dispose();
    await events.close();
  });

  /// Pushes the private chat for [peerID] over a plain page, as ChatScreen does.
  Future<void> openPrivateChat(WidgetTester tester, {String peerID = _alice, String? title = 'alice'}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => PrivateChatScreen(peerID: peerID, title: title, chatService: service),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // Not pumpAndSettle: while the start is pending the screen shows a spinner that never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> push(WidgetTester tester, Map<String, dynamic> event) async {
    events.add(event);
    await tester.pump();
    await tester.pump();
  }

  Map<String, dynamic> chats(Map<String, List<Map<String, Object?>>> byKey) =>
      {'type': 'chat_private_chats', 'chats': byKey};

  Finder screen() => find.byType(PrivateChatScreen);

  TextField composer(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField));

  testWidgets('opening asks the native core to start the chat, once', (tester) async {
    await openPrivateChat(tester);

    expect(calls.where((c) => c.startsWith('start:')), ['start:$_alice']);
  });

  testWidgets('until the native side answers, it shows the tapped name and cannot send', (tester) async {
    pendingStart = Completer<Object?>();
    await openPrivateChat(tester, title: 'alice (list)');

    expect(find.text('alice (list)'), findsOneWidget);
    expect(composer(tester).enabled, isFalse);
    composer(tester).controller!.text = 'too early';
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(calls.where((c) => c.startsWith('send')), isEmpty);

    pendingStart!.complete(_focus(_contact, name: 'alice'));
    await tester.pumpAndSettle();
    expect(composer(tester).enabled, isTrue);
  });

  testWidgets('shows the native title and the conversation under its key', (tester) async {
    await openPrivateChat(tester);

    await push(
      tester,
      chats({
        _contact: [_message('P1'), _message('P2', sender: 'me', isFromSelf: true)],
        _bob: [_message('B1', sender: 'bob')],
      }),
    );

    expect(find.text('alice'), findsWidgets);
    expect(find.text('text of P1'), findsOneWidget);
    expect(find.text('text of P2'), findsOneWidget);
    expect(find.text('text of B1'), findsNothing, reason: 'another conversation');
    // Own messages carry no sender label, as in the public chat.
    expect(find.text('me'), findsNothing);
  });

  testWidgets('a sent message shows sent, delivered and read as the native side reports them (#56)',
      (tester) async {
    await openPrivateChat(tester);
    Future<void> status(Map<String, Object?> deliveryStatus) => push(
          tester,
          chats({
            _contact: [_message('P1', sender: 'me', isFromSelf: true, deliveryStatus: deliveryStatus)],
          }),
        );

    await status({'kind': 'sending'});
    expect(find.byTooltip('傳送中…'), findsOneWidget);

    await status({'kind': 'sent'});
    expect(find.byTooltip('已送出'), findsOneWidget);

    await status({'kind': 'delivered', 'to': _alice, 'at': 1700000001000});
    expect(find.byTooltip('已送達'), findsOneWidget);

    await status({'kind': 'read', 'by': _alice, 'at': 1700000002000});
    expect(find.byTooltip('已讀'), findsOneWidget);
    expect(find.byTooltip('已送達'), findsNothing);
  });

  testWidgets('a message that could not be delivered in time is shown as failed (#56)', (tester) async {
    await openPrivateChat(tester);

    await push(
      tester,
      chats({
        _contact: [
          _message('P1', sender: 'me', isFromSelf: true, deliveryStatus: {
            'kind': 'failed',
            'reason': 'Message expired before delivery',
          }),
        ],
      }),
    );

    expect(find.byTooltip('傳送失敗：Message expired before delivery'), findsOneWidget);
  });

  testWidgets('an empty conversation says so', (tester) async {
    await openPrivateChat(tester);

    expect(find.text('還沒有私訊'), findsOneWidget);
  });

  testWidgets('sending hands the text over as this private chat\'s and clears its draft', (tester) async {
    await openPrivateChat(tester);
    calls.clear();

    await tester.enterText(find.byType(TextField), 'see you there');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(calls, [
      'updateInput[$_contact]:see you there',
      'send[$_contact]:see you there',
      'updateInput[$_contact]:',
    ]);
    expect(composer(tester).controller!.text, isEmpty);
  });

  testWidgets('text the native side refuses stays in the composer, and says it was not sent', (tester) async {
    // e.g. the peer is blocked: the native core itself declines the send.
    send = (text, privateChat) async => false;
    await openPrivateChat(tester);

    await tester.enterText(find.byType(TextField), 'see you there');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(composer(tester).controller!.text, 'see you there');
    expect(find.text('訊息沒有送出'), findsOneWidget);
  });

  testWidgets('text for a chat the native side has just changed asks to send again, and stays', (tester) async {
    // e.g. the native side has just left this chat: sending would have gone public.
    send = (text, privateChat) async => throw PlatformException(code: ChatErrors.privateChatChanged);
    await openPrivateChat(tester);

    await tester.enterText(find.byType(TextField), 'see you there');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(composer(tester).controller!.text, 'see you there');
    expect(find.text('對話狀態更新中，請再送一次'), findsOneWidget);
    expect(find.text('訊息送出失敗，請稍後再試'), findsNothing);
  });

  testWidgets('a failed send keeps the text and tells the user', (tester) async {
    send = (text, privateChat) async => throw PlatformException(code: 'boom');
    await openPrivateChat(tester);

    await tester.enterText(find.byType(TextField), 'see you there');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(composer(tester).controller!.text, 'see you there');
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('the composer starts from the draft the native side kept', (tester) async {
    startAnswer = _focus(_contact, name: 'alice', draft: 'half a senten');

    await openPrivateChat(tester);

    expect(composer(tester).controller!.text, 'half a senten');
  });

  testWidgets('it offers no / or @ completion, as the native private chat does', (tester) async {
    await openPrivateChat(tester);
    await tester.enterText(find.byType(TextField), '/h');

    // Popups the public composer asked for stay the public composer's.
    await push(tester, {
      'type': 'chat_suggestions',
      'showCommands': true,
      'commands': [
        {'command': '/hug', 'aliases': <String>[], 'syntax': '<nickname>', 'description': 'send someone a warm hug'},
      ],
      'showMentions': true,
      'mentions': <String>['bob'],
    });

    expect(find.text('/hug'), findsNothing);
    expect(find.text('@bob'), findsNothing);
    // Typing only keeps this chat's draft; the shared popup state is left alone.
    expect(calls.where((c) => c.contains('Suggestions') || c.startsWith('selectCommand')), isEmpty);
    expect(calls, contains('updateInput[$_contact]:/h'));
  });

  testWidgets('a / command typed here is still handed to the native core', (tester) async {
    await openPrivateChat(tester);
    calls.clear();

    await tester.enterText(find.byType(TextField), '/hug bob');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(calls, contains('send[$_contact]:/hug bob'));
  });

  testWidgets('it follows the native side to another conversation', (tester) async {
    await openPrivateChat(tester);
    await push(
      tester,
      chats({
        _contact: [_message('P1')],
        _bob: [_message('B1', sender: 'bob')],
      }),
    );

    // e.g. `/m bob` typed here
    await push(tester, _focus(_bob, name: 'bob', draft: 'for bob'));

    expect(find.text('bob'), findsWidgets);
    expect(find.text('text of B1'), findsOneWidget);
    expect(find.text('text of P1'), findsNothing);
    expect(composer(tester).controller!.text, 'for bob');
    await tester.enterText(find.byType(TextField), 'hi bob');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(calls, contains('send[$_bob]:hi bob'));
  });

  testWidgets('re-keying the chat keeps what is being typed', (tester) async {
    startAnswer = _focus(_alice, name: 'alice');
    await openPrivateChat(tester);
    await tester.enterText(find.byType(TextField), 'half typed');

    // The peer's Noise key arrives: upstream moves the chat to its contact conversation.
    await push(tester, _focus(_contact, name: 'alice'));

    expect(composer(tester).controller!.text, 'half typed');
  });

  testWidgets('it closes itself when the native side no longer has a private chat', (tester) async {
    await openPrivateChat(tester);

    await push(tester, _focus(null));
    await tester.pumpAndSettle();

    expect(screen(), findsNothing);
  });

  testWidgets('a stale empty selection from before the start does not close it', (tester) async {
    pendingStart = Completer<Object?>();
    await openPrivateChat(tester);

    // A snapshot built before the native side handled the start.
    await push(tester, _focus(_bob));
    await push(tester, _focus(null));
    expect(screen(), findsOneWidget);

    pendingStart!.complete(_focus(_contact, name: 'alice'));
    await tester.pumpAndSettle();
    expect(screen(), findsOneWidget);
    expect(find.text('alice'), findsWidgets);
  });

  group('favourite star (#58)', () {
    Finder star() => find.descendant(of: find.byType(AppBar), matching: find.byType(FavoriteStarButton));
    Icon starIcon(WidgetTester tester) =>
        tester.widget<Icon>(find.descendant(of: star(), matching: find.byType(Icon)));

    testWidgets('there is no star until the native side answers the start', (tester) async {
      pendingStart = Completer<Object?>();
      await openPrivateChat(tester);

      expect(star(), findsNothing);

      pendingStart!.complete(_focus(_contact, name: 'alice'));
      await tester.pumpAndSettle();
      expect(star(), findsOneWidget);
    });

    testWidgets('the star shows the native three states', (tester) async {
      startAnswer = _focus(_contact, name: 'alice');
      await openPrivateChat(tester);
      expect(starIcon(tester).icon, Icons.star_border);
      expect(starIcon(tester).color, ChatPalette.textSecondary, reason: 'grey outline: no relation');
      expect(find.byTooltip('加入最愛'), findsOneWidget);

      await push(tester, _focus(_contact, name: 'alice', theyFavoritedUs: true));
      expect(starIcon(tester).icon, Icons.star_border);
      expect(starIcon(tester).color, ChatPalette.favorite, reason: 'orange outline: they favourited us');
      expect(find.bySemanticsLabel(RegExp('已將你加入最愛')), findsOneWidget);

      await push(tester, _focus(_contact, name: 'alice', isFavorite: true, theyFavoritedUs: true));
      expect(starIcon(tester).icon, Icons.star);
      expect(starIcon(tester).color, ChatPalette.favorite, reason: 'filled orange: our favourite');
      expect(find.byTooltip('從最愛移除'), findsOneWidget);
    });

    testWidgets('tapping it toggles the favourite of the chat the native side has in focus', (tester) async {
      // Opened from the list by mesh peer ID; the native side focuses the contact conversation.
      await openPrivateChat(tester, peerID: _alice);

      await tester.tap(star());
      await tester.pump();

      expect(calls.where((c) => c.startsWith('toggleFavorite')), ['toggleFavorite:$_contact']);
      expect(screen(), findsOneWidget);
    });

    testWidgets('a failed toggle says so and keeps the chat open', (tester) async {
      toggleFavorite = (peerID) async => throw PlatformException(code: 'INVALID_ARGUMENT');
      await openPrivateChat(tester);

      await tester.tap(star());
      await tester.pump();

      expect(find.text('無法變更我的最愛，請稍後再試'), findsOneWidget);
      expect(screen(), findsOneWidget);
    });
  });
}
