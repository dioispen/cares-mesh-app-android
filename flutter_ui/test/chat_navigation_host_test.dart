import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/chat_screen.dart';
import 'package:flutter_ui/screens/private_chat_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';
import 'package:flutter_ui/widgets/chat_navigation_host.dart';

/// A `chat_selected_private_peer` map as Kotlin sends it; [peerID] null means no private chat.
Map<String, dynamic> focusEvent(String? peerID) => {
      'type': 'chat_selected_private_peer',
      'peerID': peerID,
      'conversationID': peerID,
      'displayName': peerID == null ? null : 'nick-$peerID',
      'draft': peerID == null ? null : '',
    };

const alice = 'contact_aaaa';
const bob = 'contact_bbbb';
const privateAlice = {'target': 'privateChat', 'peerID': alice, 'senderNickname': 'alice'};
const privateBob = {'target': 'privateChat', 'peerID': bob, 'senderNickname': 'bob'};
const publicChat = {'target': 'publicChat'};

void main() {
  late StreamController<Map<String, dynamic>> events;

  /// Every call that reaches Kotlin and decides where the user ends up, in order.
  late List<String> calls;

  /// What Kotlin's PendingChatNavigation holds; taken (and emptied) by chat_takePendingNavigation.
  Map<String, Object?>? nativePending;
  late Future<Object?> Function() take;

  /// Upstream refuses to open a private chat (a blocked peer): no private chat ends up selected.
  late bool refuseStart;
  late ChatService service;

  setUp(() async {
    events = StreamController<Map<String, dynamic>>.broadcast();
    calls = [];
    nativePending = null;
    refuseStart = false;
    take = () async {
      final taken = nativePending;
      nativePending = null;
      return taken;
    };
    service = ChatService(
      events: () => events.stream,
      requestSnapshot: () async {},
      sendMessage: (text, privateChat) async => true,
      updateInput: (text, privateChat) async {},
      clearSuggestions: () async {},
      startPrivateChat: (peerID) async {
        calls.add('start:$peerID');
        return focusEvent(refuseStart ? null : peerID);
      },
      endPrivateChat: () async {
        calls.add('end');
        return focusEvent(null);
      },
      takePendingNavigation: () {
        calls.add('take');
        return take();
      },
    );
  });

  tearDown(() async {
    await service.dispose();
    await events.close();
  });

  /// The user taps a notification: Kotlin holds the destination and pushes its snapshot.
  Future<void> tapNotification(WidgetTester tester, Map<String, Object?> navigation) async {
    nativePending = navigation;
    events.add({'type': 'chat_pending_navigation', 'navigation': navigation});
    await tester.pumpAndSettle();
  }

  Widget host() => ChatNavigationHost(chatService: service, child: const Scaffold(body: Text('home')));

  /// Subscribes from inside the widget test, so what the service does on an event (the host's
  /// take and navigation) runs in the test's fake-async zone and settles with the frames.
  Future<void> startService() => service.start();

  Future<void> pumpHome(WidgetTester tester) async {
    await startService();
    await tester.pumpWidget(MaterialApp(navigatorObservers: [mascotRouteObserver], home: host()));
    await tester.pumpAndSettle();
  }

  String? privateChatTitle(WidgetTester tester) {
    final screen = find.byType(PrivateChatScreen);
    if (screen.evaluate().isEmpty) return null;
    return tester
        .widgetList<Text>(find.descendant(of: screen, matching: find.byType(Text)))
        .map((text) => text.data)
        .firstWhere((data) => data != null && data.startsWith('nick-'), orElse: () => null);
  }

  group('a private message notification', () {
    testWidgets('opens that private chat, with the public chat under it and home under that', (tester) async {
      await pumpHome(tester);

      await tapNotification(tester, privateAlice);

      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(privateChatTitle(tester), 'nick-$alice');
      expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
      expect(find.text('home', skipOffstage: false), findsOneWidget);
      expect(calls.first, 'take');
      expect(calls.where((call) => call.startsWith('start')).toSet(), {'start:$alice'});

      // Back from the private chat lands in the public chat, as when opened by hand.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PrivateChatScreen), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(calls.last, 'end');
    });

    testWidgets('that started the app is opened once the signed-in home screen is up', (tester) async {
      // Cold start: Kotlin reports the tap while Dart is still on its setup / sign-in screens.
      await startService();
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [mascotRouteObserver],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => host())),
              child: const Text('sign in'),
            ),
          ),
        ),
      ));
      await tapNotification(tester, privateAlice);

      expect(calls, isEmpty, reason: 'nothing is taken, let alone opened, before signing in');
      expect(find.byType(ChatScreen), findsNothing);

      await tester.tap(find.text('sign in'));
      await tester.pumpAndSettle();

      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(privateChatTitle(tester), 'nick-$alice');
    });

    testWidgets('for someone else switches the private chat already open', (tester) async {
      await pumpHome(tester);
      await tapNotification(tester, privateAlice);

      await tapNotification(tester, privateBob);

      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(privateChatTitle(tester), 'nick-$bob');
      expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget, reason: 'no second chat room');
      expect(calls, isNot(contains('end')));
    });

    testWidgets('for the private chat already open keeps it', (tester) async {
      await pumpHome(tester);
      await tapNotification(tester, privateAlice);

      await tapNotification(tester, privateAlice);

      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(privateChatTitle(tester), 'nick-$alice');
      expect(calls, isNot(contains('end')));
    });

    testWidgets('while the public chat is open opens the private chat over it', (tester) async {
      await pumpHome(tester);
      await tapNotification(tester, publicChat);

      await tapNotification(tester, privateAlice);

      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
    });

    testWidgets('a chat upstream refuses to open leaves the user in the public chat', (tester) async {
      refuseStart = true;
      await pumpHome(tester);

      await tapNotification(tester, privateAlice);

      expect(find.byType(PrivateChatScreen), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
    });
  });

  group('a mention notification', () {
    testWidgets('opens the public chat over home', (tester) async {
      await pumpHome(tester);

      await tapNotification(tester, publicChat);

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(PrivateChatScreen), findsNothing);
      expect(calls, ['take']);
    });

    testWidgets('leaves an open private chat for the public chat under it', (tester) async {
      await pumpHome(tester);
      await tapNotification(tester, privateAlice);

      await tapNotification(tester, publicChat);

      expect(find.byType(PrivateChatScreen), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
      expect(calls.last, 'end', reason: 'closing the private chat ends it upstream');
    });

    testWidgets('while the public chat is open changes nothing', (tester) async {
      await pumpHome(tester);
      await tapNotification(tester, publicChat);

      await tapNotification(tester, publicChat);

      expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
    });
  });

  testWidgets('another screen the user was on stays under the chat, as it was', (tester) async {
    await pumpHome(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('health report form')))));
    await tester.pumpAndSettle();

    await tapNotification(tester, publicChat);
    expect(find.byType(ChatScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('health report form'), findsOneWidget);
  });

  testWidgets('dialogs and sheets on top are closed first', (tester) async {
    await pumpHome(tester);
    final context = tester.element(find.text('home'));
    unawaited(showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('confirm?'))));
    await tester.pumpAndSettle();

    await tapNotification(tester, publicChat);

    expect(find.text('confirm?'), findsNothing);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('a tap already taken goes nowhere', (tester) async {
    await pumpHome(tester);

    // A stale snapshot: Kotlin no longer holds anything.
    events.add({'type': 'chat_pending_navigation', 'navigation': publicChat});
    await tester.pumpAndSettle();

    expect(calls, ['take']);
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a failing take leaves the user where they are', (tester) async {
    take = () async => throw PlatformException(code: 'BROKEN');
    await pumpHome(tester);

    await tapNotification(tester, publicChat);

    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('the chat routes are named so a later tap finds them', (tester) async {
    expect(ChatScreen.route().settings.name, ChatScreen.routeName);
    expect(ChatScreen.routeName, isNot(PrivateChatScreen.routeName));
  });
}
