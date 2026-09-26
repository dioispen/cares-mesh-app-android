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
  late List<String> composerCalls;
  late Future<String?> Function(String command) selectCommand;
  late Future<String> Function(String nickname, String currentText) selectMention;
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
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text) => send(text),
      setNickname: (nickname) => setNickname(nickname),
      updateInput: (text) async => composerCalls.add('updateInput:$text'),
      selectCommandSuggestion: (command) {
        composerCalls.add('selectCommand:$command');
        return selectCommand(command);
      },
      selectMentionSuggestion: (nickname, currentText) {
        composerCalls.add('selectMention:$nickname|$currentText');
        return selectMention(nickname, currentText);
      },
      clearSuggestions: () async => composerCalls.add('clearSuggestions'),
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
