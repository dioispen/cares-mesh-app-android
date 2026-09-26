import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/chat_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';
import 'package:flutter_ui/widgets/peer_list_sheet.dart';

void main() {
  late StreamController<Map<String, dynamic>> events;
  late List<String> sent;
  late Future<bool> Function(String text) send;
  late List<String> nicknamesSet;
  late Future<void> Function(String nickname) setNickname;
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
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text) => send(text),
      setNickname: (nickname) => setNickname(nickname),
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
    }) =>
        {
          'peerID': peerID,
          'nickname': displayName,
          'displayName': displayName,
          'displaySuffix': displaySuffix,
          'rssi': rssi,
          'signalBars': signalBars,
          'connection': connection,
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

    testWidgets('rows are not tappable yet', (tester) async {
      await pumpChat(tester);
      await pushPeers(tester, 1, [peer('1111111111111111', displayName: 'alice')]);
      await openPeerList(tester);

      final tile = tester.widget<PeerListTile>(find.byType(PeerListTile));
      expect(tile.onTap, isNull, reason: '#55 adds opening a private chat');

      await tester.tap(inSheet(find.text('alice')));
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
    });
  });
}
