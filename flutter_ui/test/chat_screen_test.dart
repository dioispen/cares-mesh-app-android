import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/chat_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';
import 'package:flutter_ui/screens/private_chat_screen.dart';
import 'package:flutter_ui/widgets/chat_message_tile.dart' show ChatPalette;
import 'package:flutter_ui/widgets/favorite_star_button.dart';
import 'package:flutter_ui/widgets/peer_list_sheet.dart';

/// A `chat_selected_private_peer` map as Kotlin sends it; [peerID] null means no private chat.
Map<String, dynamic> focusEvent(String? peerID, {String? name, String? conversationID, String draft = ''}) => {
      'type': 'chat_selected_private_peer',
      'peerID': peerID,
      'conversationID': peerID == null ? null : (conversationID ?? peerID),
      'displayName': peerID == null ? null : (name ?? peerID),
      'draft': peerID == null ? null : draft,
    };

void main() {
  late StreamController<Map<String, dynamic>> events;
  late List<String> sent;
  late Future<bool> Function(String text) send;
  late List<String> nicknamesSet;
  late Future<void> Function(String nickname) setNickname;
  late List<String> composerCalls;
  late Future<String?> Function(String command) selectCommand;
  late Future<String> Function(String nickname, String currentText) selectMention;

  /// Every bridge call that decides where text goes, in order: `start:<id>`, `end`, and
  /// `send[<privateChat>]:<text>` (`send[public]:` for the public composer).
  late List<String> routing;
  late Future<Object?> Function(String peerID) startPrivateChat;
  late Future<Object?> Function() endPrivateChat;
  late Future<String?> Function() openLatestUnread;

  /// IDs handed to `chat_toggleFavorite`, in order (#58).
  late List<String> toggledFavorites;
  late ChatService service;

  setUp(() async {
    events = StreamController<Map<String, dynamic>>.broadcast();
    sent = [];
    send = (text) async {
      sent.add(text);
      return true;
    };
    nicknamesSet = [];
    setNickname = (nickname) async => nicknamesSet.add(nickname);
    composerCalls = [];
    selectCommand = (command) async => '$command ';
    selectMention = (nickname, currentText) async => '@$nickname ';
    routing = [];
    startPrivateChat = (peerID) async => focusEvent(peerID, name: 'nick-$peerID');
    endPrivateChat = () async => focusEvent(null);
    openLatestUnread = () async => null;
    toggledFavorites = [];
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text, privateChat) {
        routing.add('send[${privateChat ?? 'public'}]:$text');
        return send(text);
      },
      setNickname: (nickname) => setNickname(nickname),
      updateInput: (text, privateChat) async =>
          composerCalls.add(privateChat == null ? 'updateInput:$text' : 'updateInput[$privateChat]:$text'),
      startPrivateChat: (peerID) {
        routing.add('start:$peerID');
        return startPrivateChat(peerID);
      },
      endPrivateChat: () {
        routing.add('end');
        return endPrivateChat();
      },
      selectCommandSuggestion: (command) {
        composerCalls.add('selectCommand:$command');
        return selectCommand(command);
      },
      selectMentionSuggestion: (nickname, currentText) {
        composerCalls.add('selectMention:$nickname|$currentText');
        return selectMention(nickname, currentText);
      },
      clearSuggestions: () async => composerCalls.add('clearSuggestions'),
      openLatestUnreadPrivateChat: () {
        routing.add('openLatestUnread');
        return openLatestUnread();
      },
      toggleFavorite: (peerID) async => toggledFavorites.add(peerID),
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
    bool mentionsMe = false,
    List<Map<String, Object?>> mentionSpans = const [],
  }) =>
      {
        'id': id,
        'sender': sender,
        'content': content,
        'timestamp': DateTime(2024, 5, 1, 9, 7).millisecondsSinceEpoch,
        'isFromSelf': isFromSelf,
        'isSystem': isSystem,
        'mentionsMe': mentionsMe,
        'mentionSpans': mentionSpans,
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

  group('mesh nickname', () {
    Future<void> pushNickname(WidgetTester tester, String nickname) async {
      events.add({'type': 'chat_nickname', 'nickname': nickname});
      await tester.pump();
      await tester.pump();
    }

    Finder editButton() => find.byTooltip('修改 mesh 暱稱');
    Finder dialogField() =>
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

    Future<void> openEditor(WidgetTester tester) async {
      await tester.tap(editButton());
      await tester.pumpAndSettle();
    }

    testWidgets('the app bar shows the mesh nickname', (tester) async {
      await pumpChat(tester);

      await pushNickname(tester, 'anon4821');

      expect(find.text('@anon4821'), findsOneWidget);
    });

    testWidgets('there is nothing to edit until the native side reports a nickname',
        (tester) async {
      await pumpChat(tester);

      expect(editButton(), findsNothing);
    });

    testWidgets('the app bar follows a nickname changed anywhere upstream', (tester) async {
      await pumpChat(tester);
      await pushNickname(tester, 'anon4821');

      await pushNickname(tester, 'anon1234');

      expect(find.text('@anon1234'), findsOneWidget);
      expect(find.text('@anon4821'), findsNothing);
    });

    testWidgets('the editor starts from the mesh nickname', (tester) async {
      await pumpChat(tester);
      await pushNickname(tester, 'anon4821');

      await openEditor(tester);

      expect(tester.widget<TextField>(dialogField()).controller!.text, 'anon4821');
    });

    testWidgets('saving hands exactly what was typed to ChatService and closes', (tester) async {
      await pumpChat(tester);
      await pushNickname(tester, 'anon4821');
      await openEditor(tester);

      await tester.enterText(dialogField(), ' bob ');
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();

      expect(nicknamesSet, [' bob ']);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a blank nickname is left for upstream to handle', (tester) async {
      await pumpChat(tester);
      await pushNickname(tester, 'anon4821');
      await openEditor(tester);

      await tester.enterText(dialogField(), '');
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();

      expect(nicknamesSet, ['']);
    });

    testWidgets('cancelling leaves the nickname alone', (tester) async {
      await pumpChat(tester);
      await pushNickname(tester, 'anon4821');
      await openEditor(tester);

      await tester.enterText(dialogField(), 'bob');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(nicknamesSet, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a failed save keeps the editor open and says so', (tester) async {
      setNickname = (nickname) async => throw MissingPluginException('no native side');
      await pumpChat(tester);
      await pushNickname(tester, 'anon4821');
      await openEditor(tester);

      await tester.enterText(dialogField(), 'bob');
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('暱稱更新失敗，請稍後再試'), findsOneWidget);
      expect(tester.widget<TextField>(dialogField()).controller!.text, 'bob');
    });

    testWidgets('the editor warns that the nickname is broadcast in the clear', (tester) async {
      await pumpChat(tester);
      await pushNickname(tester, 'anon4821');

      await openEditor(tester);

      expect(find.textContaining('請勿使用真實姓名'), findsOneWidget);
    });
  });

  group('mesh peers', () {
    Map<String, Object?> peer(
      String peerID, {
      String displayName = 'alice',
      String displaySuffix = '',
      int? rssi = -67,
      int? signalBars = 2,
      String connection = 'bluetooth',
      int unreadCount = 0,
      bool isFavorite = false,
      bool theyFavoritedUs = false,
    }) =>
        {
          'peerID': peerID,
          'nickname': displayName,
          'displayName': displayName,
          'displaySuffix': displaySuffix,
          'rssi': rssi,
          'signalBars': signalBars,
          'connection': connection,
          'unreadCount': unreadCount,
          'isFavorite': isFavorite,
          'theyFavoritedUs': theyFavoritedUs,
        };

    Future<void> pushPeers(WidgetTester tester, int onlineCount, List<Map<String, Object?>> peers) async {
      events.add({'type': 'chat_peers', 'onlineCount': onlineCount, 'peers': peers});
      await tester.pump();
      await tester.pump();
    }

    Finder peerCount() => find.byTooltip('附近的人');
    Finder inCount(String text) => find.descendant(of: peerCount(), matching: find.text(text));
    Finder sheet() => find.byType(PeerListSheet);
    Finder inSheet(Finder finder) => find.descendant(of: sheet(), matching: finder);

    Future<void> openPeerList(WidgetTester tester) async {
      await tester.tap(peerCount());
      await tester.pumpAndSettle();
    }

    testWidgets('there is no count until the native side reports the peers', (tester) async {
      await pumpChat(tester);

      expect(peerCount(), findsNothing);
    });

    testWidgets('the app bar shows the online count next to the nickname', (tester) async {
      await pumpChat(tester);
      events.add({'type': 'chat_nickname', 'nickname': 'anon4821'});

      await pushPeers(tester, 2, [peer('1111111111111111'), peer('2222222222222222', displayName: 'bob')]);

      expect(inCount('2'), findsOneWidget);
      expect(find.text('@anon4821'), findsOneWidget);
    });

    testWidgets('the count follows peers joining and leaving', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 1, [peer('1111111111111111')]);

      await pushPeers(tester, 2, [peer('1111111111111111'), peer('2222222222222222', displayName: 'bob')]);
      expect(inCount('2'), findsOneWidget);

      await pushPeers(tester, 0, []);
      expect(inCount('0'), findsOneWidget);
    });

    testWidgets('tapping the count lists each peer with name, link and signal', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 3, [
        peer('1111111111111111', displayName: 'alice', rssi: -48, signalBars: 2, connection: 'bluetooth'),
        peer('2222222222222222', displayName: 'bob', rssi: null, signalBars: null, connection: 'routed'),
        peer('3333333333333333', displayName: 'carol', rssi: -80, signalBars: 1, connection: 'wifiAware'),
      ]);

      await openPeerList(tester);

      expect(inSheet(find.text('附近的人（3）')), findsOneWidget);
      expect(inSheet(find.text('alice')), findsOneWidget);
      expect(inSheet(find.text('-48 dBm')), findsOneWidget);
      expect(inSheet(find.text('藍牙直連')), findsOneWidget);
      expect(inSheet(find.text('bob')), findsOneWidget);
      expect(inSheet(find.text('經 mesh 轉傳')), findsOneWidget);
      expect(inSheet(find.byTooltip('沒有直接連線，無訊號強度')), findsOneWidget);
      expect(inSheet(find.text('Wi-Fi Aware 直連')), findsOneWidget);
      expect(inSheet(find.text('-80 dBm')), findsOneWidget);
    });

    testWidgets('peers are listed in the order the native side sends', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 2, [
        peer('2222222222222222', displayName: 'zoe'),
        peer('1111111111111111', displayName: 'amy'),
      ]);

      await openPeerList(tester);

      final zoe = tester.getTopLeft(inSheet(find.text('zoe'))).dy;
      final amy = tester.getTopLeft(inSheet(find.text('amy'))).dy;
      expect(zoe, lessThan(amy), reason: 'Dart must not re-sort');
    });

    testWidgets('a shared name shows its dimmed hash suffix', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 2, [
        peer('1111111111111111', displayName: 'sam', displaySuffix: '#0a1b'),
        peer('2222222222222222', displayName: 'sam', displaySuffix: '#ffff'),
      ]);

      await openPeerList(tester);

      expect(inSheet(find.text('sam#0a1b', findRichText: true)), findsOneWidget);
      expect(inSheet(find.text('sam#ffff', findRichText: true)), findsOneWidget);
    });

    testWidgets('the open list updates as peers come and go', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice')]);
      await openPeerList(tester);

      await pushPeers(tester, 1, [peer('2222222222222222', displayName: 'bob')]);

      expect(inSheet(find.text('alice')), findsNothing);
      expect(inSheet(find.text('bob')), findsOneWidget);
    });

    testWidgets('nobody online says so', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 0, []);

      await openPeerList(tester);

      expect(inSheet(find.text('目前沒有人連線')), findsOneWidget);
    });

    testWidgets('tapping a peer closes the list and opens a private chat with them (#55)', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice')]);
      await openPeerList(tester);

      await tester.tap(inSheet(find.text('alice')));
      await tester.pumpAndSettle();

      expect(sheet(), findsNothing);
      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(routing, ['start:1111111111111111']);
    });

    testWidgets('a peer with unread private messages shows how many, as the native list does (#56)',
        (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 3, [
        peer('1111111111111111', displayName: 'alice', unreadCount: 3),
        peer('2222222222222222', displayName: 'bob', unreadCount: 120),
        peer('3333333333333333', displayName: 'carol'),
      ]);
      await openPeerList(tester);

      expect(inSheet(find.byTooltip('3 則未讀私訊')), findsOneWidget);
      expect(inSheet(find.text('3')), findsOneWidget);
      expect(inSheet(find.text('99+')), findsOneWidget, reason: 'upstream caps the badge at 99+');
      expect(inSheet(find.byType(UnreadBadge)), findsNWidgets(2), reason: 'no badge without unread messages');
    });

    testWidgets('the badge goes once the native side reports the chat read (#56)', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice', unreadCount: 2)]);
      await openPeerList(tester);
      expect(inSheet(find.byTooltip('2 則未讀私訊')), findsOneWidget);

      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice')]);

      expect(inSheet(find.byType(UnreadBadge)), findsNothing);
    });

    // --- favourites (#58) ---------------------------------------------------------------------

    Finder starOf(String name) => find.descendant(
          of: find.ancestor(of: inSheet(find.text(name)), matching: find.byType(PeerListTile)),
          matching: find.byType(FavoriteStarButton),
        );

    Icon starIcon(WidgetTester tester, String name) =>
        tester.widget<Icon>(find.descendant(of: starOf(name), matching: find.byType(Icon)));

    testWidgets('each row\'s star shows the native three states', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 3, [
        peer('1111111111111111', displayName: 'alice', isFavorite: true),
        peer('2222222222222222', displayName: 'bob', theyFavoritedUs: true),
        peer('3333333333333333', displayName: 'carol'),
      ]);
      await openPeerList(tester);

      // Filled orange: our favourite. Orange outline: they favourited us. Grey outline: neither.
      expect(starIcon(tester, 'alice').icon, Icons.star);
      expect(starIcon(tester, 'alice').color, ChatPalette.favorite);
      expect(starIcon(tester, 'bob').icon, Icons.star_border);
      expect(starIcon(tester, 'bob').color, ChatPalette.favorite);
      expect(starIcon(tester, 'carol').icon, Icons.star_border);
      expect(starIcon(tester, 'carol').color, ChatPalette.textSecondary);
      expect(find.descendant(of: starOf('alice'), matching: find.byTooltip('從最愛移除')), findsOneWidget);
      expect(find.descendant(of: starOf('carol'), matching: find.byTooltip('加入最愛')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('已將你加入最愛')), findsOneWidget, reason: 'bob favourited us');
    });

    testWidgets('a row\'s star toggles the favourite and leaves the list open', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice')]);
      await openPeerList(tester);

      await tester.tap(starOf('alice'));
      await tester.pumpAndSettle();

      expect(toggledFavorites, ['1111111111111111']);
      expect(routing, isEmpty, reason: 'the star is not the row: no private chat opens');
      expect(sheet(), findsOneWidget);
    });

    testWidgets('the star follows the native side, not the tap', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice')]);
      await openPeerList(tester);

      await tester.tap(starOf('alice'));
      await tester.pump();
      expect(starIcon(tester, 'alice').icon, Icons.star_border, reason: 'nothing changes before Kotlin reports it');

      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice', isFavorite: true)]);
      expect(starIcon(tester, 'alice').icon, Icons.star);
    });

    testWidgets('an offline favourite is listed as such and opens a private chat by its key', (tester) async {
      final noiseKey = 'd' * 64;
      await pumpChat(tester);
      await pushPeers(tester, 0, [
        peer(noiseKey, displayName: 'dora', rssi: null, signalBars: null, connection: 'offline', isFavorite: true),
      ]);
      await openPeerList(tester);

      expect(inSheet(find.text('附近的人（0）')), findsOneWidget);
      expect(inSheet(find.text('目前沒有人連線')), findsNothing);
      expect(inSheet(find.text('離線最愛')), findsOneWidget);
      expect(starIcon(tester, 'dora').icon, Icons.star);

      await tester.tap(inSheet(find.text('dora')));
      await tester.pumpAndSettle();

      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(routing, ['start:$noiseKey']);
    });
  });

  group('private chats (#55)', () {
    const alice = '1111111111111111';
    const contact = 'contact_aaaa';

    Finder privateChat() => find.byType(PrivateChatScreen);

    Future<void> pushFocus(WidgetTester tester, String? peerID, {String? name}) async {
      events.add(focusEvent(peerID, name: name));
      await tester.pump();
      await tester.pump();
    }

    Future<void> openFromPeerList(WidgetTester tester) async {
      events.add({
        'type': 'chat_peers',
        'onlineCount': 1,
        'peers': [
          {'peerID': alice, 'nickname': 'alice', 'displayName': 'alice', 'displaySuffix': '', 'connection': 'bluetooth'},
        ],
      });
      await tester.pump();
      await tester.tap(find.byTooltip('附近的人'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(PeerListSheet), matching: find.text('alice')));
      await tester.pumpAndSettle();
      expect(privateChat(), findsOneWidget);
    }

    Future<void> sendPublic(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
    }

    testWidgets('/m opens the private chat the native side selected', (tester) async {
      startPrivateChat = (peerID) async => focusEvent(peerID, name: 'alice');
      await pumpChat(tester);

      await sendPublic(tester, '/m alice');
      // Upstream's /m selects the peer (CommandProcessor); Flutter only follows the snapshot.
      await pushFocus(tester, contact, name: 'alice');
      await tester.pumpAndSettle();

      expect(sent, ['/m alice']);
      expect(privateChat(), findsOneWidget);
      expect(find.text('alice'), findsWidgets);
      // The screen runs upstream's full open (stored history, notifications) for that chat.
      expect(routing, ['send[public]:/m alice', 'start:$contact']);
    });

    testWidgets('leaving with the app bar back button ends the private chat before anything else is sent',
        (tester) async {
      await pumpChat(tester);
      await openFromPeerList(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await sendPublic(tester, 'anyone at the gym?');

      expect(privateChat(), findsNothing);
      expect(routing, ['start:$alice', 'end', 'send[public]:anyone at the gym?']);
      expect(service.selectedPrivateChat.value, isNull);
    });

    testWidgets('leaving with the system back button or gesture ends the private chat too', (tester) async {
      await pumpChat(tester);
      await openFromPeerList(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await sendPublic(tester, 'anyone at the gym?');

      expect(privateChat(), findsNothing);
      expect(routing, ['start:$alice', 'end', 'send[public]:anyone at the gym?']);
    });

    testWidgets('a private chat the native side ends by itself closes, and is ended here too', (tester) async {
      await pumpChat(tester);
      await openFromPeerList(tester);

      // e.g. `/block` of this peer, the conversation deleted, a panic reset
      await pushFocus(tester, null);
      await tester.pumpAndSettle();

      expect(privateChat(), findsNothing);
      expect(routing.last, 'end');
    });

    testWidgets('a start the native side refuses closes the private chat again', (tester) async {
      // e.g. a blocked peer: upstream posts a system line to the public chat and selects nothing.
      startPrivateChat = (peerID) async => focusEvent(null);
      await pumpChat(tester);
      events.add({
        'type': 'chat_peers',
        'onlineCount': 1,
        'peers': [
          {'peerID': alice, 'nickname': 'alice', 'displayName': 'alice', 'displaySuffix': '', 'connection': 'bluetooth'},
        ],
      });
      await tester.pump();
      await tester.tap(find.byTooltip('附近的人'));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(of: find.byType(PeerListSheet), matching: find.text('alice')));
      await tester.pumpAndSettle();

      expect(privateChat(), findsNothing);
      expect(routing, ['start:$alice', 'end']);
    });

    testWidgets('a failing start closes the private chat and says so', (tester) async {
      startPrivateChat = (peerID) async => throw PlatformException(code: 'PRIVATE_CHAT_FAILED');
      await pumpChat(tester);
      events.add({
        'type': 'chat_peers',
        'onlineCount': 1,
        'peers': [
          {'peerID': alice, 'nickname': 'alice', 'displayName': 'alice', 'displaySuffix': '', 'connection': 'bluetooth'},
        ],
      });
      await tester.pump();
      await tester.tap(find.byTooltip('附近的人'));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(of: find.byType(PeerListSheet), matching: find.text('alice')));
      await tester.pumpAndSettle();

      expect(privateChat(), findsNothing);
      expect(find.text('無法開啟私訊，請稍後再試'), findsOneWidget);
    });

    testWidgets('a private chat the native side still has when the chat opens is shown again', (tester) async {
      // Selected upstream before this screen opened (e.g. from a notification, #57). Activity
      // recreation no longer leaves one behind: the old engine's ChatBridge ends it (#56).
      events.add(focusEvent(contact, name: 'alice'));
      await tester.pump();

      await pumpChat(tester);
      await tester.pumpAndSettle();

      expect(privateChat(), findsOneWidget);
      expect(routing, ['start:$contact']);
    });

    testWidgets('a stale selection that arrives while the chat is being ended does not reopen it',
        (tester) async {
      final ended = Completer<Object?>();
      endPrivateChat = () => ended.future;
      await pumpChat(tester);
      await openFromPeerList(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      // Sent by Kotlin before it handled the end (e.g. the peer ID re-keyed to its contact ID).
      await pushFocus(tester, contact, name: 'alice');
      await tester.pumpAndSettle();
      expect(privateChat(), findsNothing);

      ended.complete(focusEvent(null));
      await tester.pumpAndSettle();

      expect(privateChat(), findsNothing);
      expect(service.selectedPrivateChat.value, isNull);
    });

    testWidgets('while the private chat is open, sends only ever come from its own composer', (tester) async {
      await pumpChat(tester);
      await openFromPeerList(tester);

      await tester.enterText(find.byType(TextField), 'see you there');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(routing, ['start:$alice', 'send[$alice]:see you there']);
    });
  });

  group('unread private messages (#56)', () {
    const contact = 'contact_aaaa';

    Future<void> pushUnread(WidgetTester tester, {bool hasUnread = true}) async {
      events.add({
        'type': 'chat_unread',
        'hasUnread': hasUnread,
        'conversations': hasUnread ? {contact: 2} : <String, int>{},
      });
      await tester.pump();
      await tester.pump();
    }

    Finder envelope() => find.byTooltip('未讀私訊');

    testWidgets('there is no envelope while nothing is unread', (tester) async {
      await pumpChat(tester);
      expect(envelope(), findsNothing);

      await pushUnread(tester, hasUnread: false);
      expect(envelope(), findsNothing);
    });

    testWidgets('the envelope shows while the native side has unread private messages', (tester) async {
      await pumpChat(tester);

      await pushUnread(tester);
      expect(envelope(), findsOneWidget);

      // Opening the chat (here or anywhere upstream) reads it; the envelope follows the snapshot.
      await pushUnread(tester, hasUnread: false);
      expect(envelope(), findsNothing);
    });

    testWidgets('the envelope opens the conversation the native side picks', (tester) async {
      openLatestUnread = () async => contact;
      await pumpChat(tester);
      await pushUnread(tester);

      await tester.tap(envelope());
      await tester.pumpAndSettle();

      expect(find.byType(PrivateChatScreen), findsOneWidget);
      // The private chat screen starts it like any other; upstream's start clears its unread mark.
      expect(routing, ['openLatestUnread', 'start:$contact']);
    });

    testWidgets('nothing left to open leaves the chat as it is', (tester) async {
      await pumpChat(tester);
      await pushUnread(tester);

      await tester.tap(envelope());
      await tester.pumpAndSettle();

      expect(find.byType(PrivateChatScreen), findsNothing);
      expect(routing, ['openLatestUnread']);
    });

    testWidgets('a failing request leaves the chat as it is', (tester) async {
      openLatestUnread = () async => throw MissingPluginException('no native side');
      await pumpChat(tester);
      await pushUnread(tester);

      await tester.tap(envelope());
      await tester.pumpAndSettle();

      expect(find.byType(PrivateChatScreen), findsNothing);
    });
  });

  group('mention and command suggestions (#54)', () {
    Map<String, Object?> command(String command,
            {List<String> aliases = const [], String? syntax, String description = ''}) =>
        {'command': command, 'aliases': aliases, 'syntax': syntax, 'description': description};

    Future<void> pushSuggestions(
      WidgetTester tester, {
      bool showCommands = false,
      List<Map<String, Object?>> commands = const [],
      bool showMentions = false,
      List<String> mentions = const [],
    }) async {
      events.add({
        'type': 'chat_suggestions',
        'showCommands': showCommands,
        'commands': commands,
        'showMentions': showMentions,
        'mentions': mentions,
      });
      await tester.pump();
      await tester.pump();
    }

    TextEditingController composer(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!;

    testWidgets('opening the chat clears popups left over from an earlier composer', (tester) async {
      await pumpChat(tester);

      expect(composerCalls, ['clearSuggestions']);
    });

    testWidgets('every edit is handed to the native core as it is typed', (tester) async {
      await pumpChat(tester);
      composerCalls.clear();

      await tester.enterText(find.byType(TextField), '/');
      await tester.enterText(find.byType(TextField), '/h');
      await tester.enterText(find.byType(TextField), 'hi @al');

      expect(composerCalls, ['updateInput:/', 'updateInput:/h', 'updateInput:hi @al']);
    });

    testWidgets('no popup until the native side offers one', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '/');

      expect(find.text('/hug'), findsNothing);
      expect(find.text('提及'), findsNothing);
    });

    testWidgets('the native command list is shown above the composer', (tester) async {
      await pumpChat(tester);

      await pushSuggestions(tester, showCommands: true, commands: [
        command('/hug', syntax: '<nickname>', description: 'send someone a warm hug'),
        command('/j', aliases: ['/join'], syntax: '<channel>', description: 'join or create a channel'),
        command('/w', description: "see who's online"),
      ]);

      expect(find.text('/hug'), findsOneWidget);
      expect(find.text('<nickname>'), findsOneWidget);
      expect(find.text('send someone a warm hug'), findsOneWidget);
      expect(find.text('/j, /join'), findsOneWidget);
      expect(find.text("see who's online"), findsOneWidget);
      final hug = tester.getTopLeft(find.text('/hug')).dy;
      final w = tester.getTopLeft(find.text('/w')).dy;
      expect(hug, lessThan(w), reason: 'in the order the native side sends');
      expect(w, lessThan(tester.getTopLeft(find.byType(TextField)).dy));
    });

    testWidgets('a popup the native side hides is not shown, list or not', (tester) async {
      await pumpChat(tester);

      await pushSuggestions(tester,
          showCommands: false, commands: [command('/hug')], showMentions: false, mentions: ['alice']);

      expect(find.text('/hug'), findsNothing);
      expect(find.text('@alice'), findsNothing);
    });

    testWidgets('the popup goes away when the native side hides it', (tester) async {
      await pumpChat(tester);
      await pushSuggestions(tester, showCommands: true, commands: [command('/hug')]);

      await pushSuggestions(tester);

      expect(find.text('/hug'), findsNothing);
    });

    testWidgets('choosing a command puts the native text in the field, cursor at the end', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '/h');
      await pushSuggestions(tester, showCommands: true, commands: [command('/hug', syntax: '<nickname>')]);
      composerCalls.clear();

      await tester.tap(find.text('/hug'));
      await tester.pump();

      expect(composerCalls, ['selectCommand:/hug']);
      expect(composer(tester).text, '/hug ');
      expect(composer(tester).selection, const TextSelection.collapsed(offset: 5));
    });

    testWidgets('a command the native side no longer offers leaves the field alone', (tester) async {
      selectCommand = (command) async => null;
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '/h');
      await pushSuggestions(tester, showCommands: true, commands: [command('/hug')]);

      await tester.tap(find.text('/hug'));
      await tester.pump();

      expect(composer(tester).text, '/h');
    });

    testWidgets('online nicknames are offered as @mentions', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'hi @');

      await pushSuggestions(tester, showMentions: true, mentions: ['alice', '小明']);

      expect(find.text('@alice'), findsOneWidget);
      expect(find.text('@小明'), findsOneWidget);
      expect(find.text('提及'), findsNWidgets(2));
    });

    testWidgets('choosing a mention hands over the typed text and inserts the native result', (tester) async {
      selectMention = (nickname, currentText) async => 'hi @$nickname ';
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'hi @al');
      await pushSuggestions(tester, showMentions: true, mentions: ['alice']);
      composerCalls.clear();

      await tester.tap(find.text('@alice'));
      await tester.pump();

      expect(composerCalls, ['selectMention:alice|hi @al']);
      expect(composer(tester).text, 'hi @alice ');
      expect(composer(tester).selection, const TextSelection.collapsed(offset: 10));
    });

    testWidgets('a mention result that arrives after more typing does not overwrite it', (tester) async {
      final answer = Completer<String>();
      selectMention = (nickname, currentText) => answer.future;
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'hi @al');
      await pushSuggestions(tester, showMentions: true, mentions: ['alice']);

      await tester.tap(find.text('@alice'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hi @alx');
      answer.complete('hi @alice ');
      await tester.pump();

      expect(composer(tester).text, 'hi @alx');
    });

    testWidgets('a failed selection keeps the field and does not crash', (tester) async {
      selectMention = (nickname, currentText) async => throw PlatformException(code: 'boom');
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '@al');
      await pushSuggestions(tester, showMentions: true, mentions: ['alice']);

      await tester.tap(find.text('@alice'));
      await tester.pump();

      expect(composer(tester).text, '@al');
    });

    testWidgets('an accepted send clears the popups, as the native composer does', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '/w');
      composerCalls.clear();

      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(sent, ['/w']);
      expect(composerCalls, ['clearSuggestions']);
    });

    testWidgets('a refused send keeps the popups', (tester) async {
      send = (text) async => false;
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '/w');
      composerCalls.clear();

      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(composerCalls, isEmpty);
    });
  });

  group('mentions of me (#54)', () {
    List<TextSpan> spansOf(WidgetTester tester, String text) {
      final spans = <TextSpan>[];
      tester.widget<Text>(find.text(text)).textSpan?.visitChildren((span) {
        if (span is TextSpan && span.text != null) spans.add(span);
        return true;
      });
      return spans;
    }

    testWidgets('a message that mentions me is marked', (tester) async {
      await pumpChat(tester);

      await pushTimeline(tester, [
        message('A', sender: 'alice', content: 'hey @me', mentionsMe: true, mentionSpans: [
          {'start': 4, 'end': 7, 'isMe': true},
        ]),
        message('B', sender: 'bob', content: 'hey @carol', mentionSpans: [
          {'start': 4, 'end': 10, 'isMe': false},
        ]),
      ]);

      expect(find.text('提及你'), findsOneWidget);
      final mark = tester.getTopLeft(find.text('提及你')).dy;
      expect(mark, lessThan(tester.getTopLeft(find.text('hey @me')).dy));
      expect(mark, lessThan(tester.getTopLeft(find.text('bob')).dy));
    });

    testWidgets('the mark follows mentionsMe only, not the spans', (tester) async {
      await pumpChat(tester);

      // Our own note to ourselves: Kotlin flags the token as ours but not the message.
      await pushTimeline(tester, [
        message('A', sender: 'me', content: 'note to @me', isFromSelf: true, mentionSpans: [
          {'start': 8, 'end': 11, 'isMe': true},
        ]),
      ]);

      expect(find.text('提及你'), findsNothing);
    });

    testWidgets('mention tokens are emphasised in the text, mine the most', (tester) async {
      await pumpChat(tester);

      await pushTimeline(tester, [
        message('A', content: 'hi @bob and @me!', mentionsMe: true, mentionSpans: [
          {'start': 3, 'end': 7, 'isMe': false},
          {'start': 12, 'end': 15, 'isMe': true},
        ]),
      ]);

      final spans = spansOf(tester, 'hi @bob and @me!');
      expect(spans.map((s) => s.text), ['hi ', '@bob', ' and ', '@me', '!']);
      final bob = spans[1].style!;
      final me = spans[3].style!;
      expect(bob.fontWeight, FontWeight.w600);
      expect(me.fontWeight, FontWeight.w700);
      expect(me.backgroundColor, isNotNull);
      expect(me.color, isNot(bob.color));
    });

    testWidgets('a message without mentions is plain text', (tester) async {
      await pumpChat(tester);

      await pushTimeline(tester, [message('A', content: 'plain words')]);

      expect(spansOf(tester, 'plain words'), isEmpty);
      expect(tester.widget<Text>(find.text('plain words')).data, 'plain words');
    });
  });
}
