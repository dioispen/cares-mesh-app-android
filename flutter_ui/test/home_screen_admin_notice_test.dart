import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/admin_notice_screen.dart';
import 'package:flutter_ui/screens/home_screen.dart';
import 'package:flutter_ui/services/admin_notice_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_admin_notice_native.dart';
import 'support/screen_sizes.dart';

/// The home screen's way into the Admin Notice list (#142): the unread count, and the card that
/// stands in for notifications when POST_NOTIFICATIONS is not granted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeAdminNoticeNative native;
  late AdminNoticeService service;
  final now = DateTime(2026, 10, 22, 9);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Everything else the home screen reaches (chat, settings) has no native side here.
    messenger.setMockMethodCallHandler(channel, (call) async => throw MissingPluginException(call.method));
    native = FakeAdminNoticeNative();
    service = native.service();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    service.dispose();
  });

  Future<void> openHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await service.start();
    await tester.pumpWidget(MaterialApp(home: HomeScreen(adminNotices: service, clock: () => now)));
    await tester.pump();
  }

  final entry = find.byKey(const ValueKey('admin-notice-entry'));
  final card = find.byKey(const ValueKey('admin-notice-home-card'));
  Finder unreadBadge(String count) => find.descendant(of: entry, matching: find.text(count));

  group('unread count', () {
    testWidgets('the header shows how many notices are unread', (tester) async {
      native.stored = [
        adminNoticeMap('1111111111111111'),
        adminNoticeMap('2222222222222222', status: 'withdrawn'),
        adminNoticeMap('3333333333333333', read: true),
      ];

      await openHome(tester);

      expect(entry, findsOneWidget);
      expect(unreadBadge('2'), findsOneWidget);
    });

    testWidgets('with everything read there is no count', (tester) async {
      native.stored = [adminNoticeMap('1111111111111111', read: true)];

      await openHome(tester);

      expect(entry, findsOneWidget);
      expect(find.descendant(of: entry, matching: find.byType(Text)), findsNothing);
    });

    testWidgets('it follows the admin_notice events', (tester) async {
      await openHome(tester);

      native.receive(adminNoticeMap('1111111111111111'));
      await tester.pumpAndSettle();
      expect(unreadBadge('1'), findsOneWidget);

      native.receive(adminNoticeMap('2222222222222222'));
      await tester.pumpAndSettle();
      expect(unreadBadge('2'), findsOneWidget);
    });

    testWidgets('the entry opens the list, which reads the notices, and the count is gone after', (tester) async {
      native.stored = [adminNoticeMap('1111111111111111'), adminNoticeMap('2222222222222222')];
      await openHome(tester);

      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(AdminNoticeScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(native.markedRead, unorderedEquals(['1111111111111111', '2222222222222222']));
      expect(find.descendant(of: entry, matching: find.byType(Text)), findsNothing);
    });
  });

  group('without notification permission', () {
    setUp(() => native.systemStatus = {'type': 'system_status', 'notificationGranted': false});

    testWidgets('the newest unread notice in force is shown as a card', (tester) async {
      native.stored = [
        adminNoticeMap('1111111111111111', content: '這則已撤回', status: 'withdrawn', issuedAt: DateTime(2026, 10, 22, 8, 50)),
        adminNoticeMap('2222222222222222', content: '這則已過期', issuedAt: DateTime(2026, 10, 22, 8, 40),
            expiresAt: DateTime(2026, 10, 22, 8, 55)),
        adminNoticeMap('3333333333333333', content: '土石流警戒：請立即撤離', level: 'urgent', issuedAt: DateTime(2026, 10, 22, 8, 30)),
        adminNoticeMap('4444444444444444', content: '大同國小避難所已開放', level: 'important', issuedAt: DateTime(2026, 10, 22, 8)),
      ];

      await openHome(tester);

      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('土石流警戒：請立即撤離')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('緊急')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('10/22 08:30')), findsOneWidget);
      for (final other in ['這則已撤回', '這則已過期', '大同國小避難所已開放']) {
        expect(find.text(other), findsNothing, reason: other);
      }
    });

    testWidgets('a notice that arrives shows up on the card at once', (tester) async {
      await openHome(tester);
      expect(card, findsNothing);

      native.receive(adminNoticeMap('1111111111111111', content: '土石流警戒：請立即撤離'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: card, matching: find.text('土石流警戒：請立即撤離')), findsOneWidget);
    });

    testWidgets('tapping the card opens the list; once read, the card is gone', (tester) async {
      native.stored = [adminNoticeMap('1111111111111111', content: '土石流警戒：請立即撤離')];
      await openHome(tester);

      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(AdminNoticeScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(card, findsNothing);
    });

    testWidgets('allowing notifications in the system settings removes the card on return', (tester) async {
      native.stored = [adminNoticeMap('1111111111111111')];
      await openHome(tester);
      expect(card, findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      native.systemStatus = {'type': 'system_status', 'notificationGranted': true};
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(card, findsNothing);
    });

    for (final screen in layoutCases) {
      testWidgets('a long notice on the card fits on $screen', (tester) async {
        native.stored = [adminNoticeMap('1111111111111111', content: '土石流警戒' * 30)];
        await service.start();
        useScreen(tester, screen);

        await tester.pumpWidget(MaterialApp(home: HomeScreen(adminNotices: service, clock: () => now)));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(card, findsOneWidget);
      });
    }
  });

  testWidgets('with notification permission there is no card', (tester) async {
    native.stored = [adminNoticeMap('1111111111111111', content: '土石流警戒：請立即撤離')];

    await openHome(tester);

    expect(card, findsNothing);
    expect(unreadBadge('1'), findsOneWidget);
  });

  testWidgets('while it is not known whether notifications are allowed there is no card', (tester) async {
    native
      ..systemStatus = null
      ..stored = [adminNoticeMap('1111111111111111')];

    await openHome(tester);

    expect(card, findsNothing);
  });
}
