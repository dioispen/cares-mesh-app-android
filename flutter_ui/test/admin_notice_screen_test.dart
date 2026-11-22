import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/admin_notice_screen.dart';
import 'package:flutter_ui/services/admin_notice_service.dart';

import 'support/fake_admin_notice_native.dart';
import 'support/screen_sizes.dart';

/// The Admin Notice list (#142, docs/ADMIN_NOTICE_V1.md 收件端呈現) over a fake native bridge.
void main() {
  late FakeAdminNoticeNative native;
  late AdminNoticeService service;

  /// The screen's clock: 09:00 on the day the notices below were issued.
  final now = DateTime(2026, 10, 22, 9);

  setUp(() {
    native = FakeAdminNoticeNative();
    service = native.service();
  });

  tearDown(() => service.dispose());

  Future<void> openList(WidgetTester tester) async {
    await service.start();
    await tester.pumpWidget(MaterialApp(home: AdminNoticeScreen(service: service, clock: () => now)));
    await tester.pump();
  }

  testWidgets('each notice shows its level, content and time', (tester) async {
    native.stored = [
      adminNoticeMap('a1b2c3d4e5f60718', level: 'urgent', content: '土石流警戒：請立即撤離至大同國小避難所', issuedAt: DateTime(2026, 10, 22, 8, 30)),
      adminNoticeMap('0f1e2d3c4b5a6978', level: 'important', content: '大同國小避難所已開放', issuedAt: DateTime(2026, 10, 22, 7, 5)),
      adminNoticeMap('1122334455667788', level: 'info', content: '飲用水明早送達', issuedAt: DateTime(2026, 10, 21, 22, 0)),
    ];

    await openList(tester);

    expect(find.text('管理端公告'), findsOneWidget);
    for (final (messageId, level, content, time) in const [
      ('a1b2c3d4e5f60718', '緊急', '土石流警戒：請立即撤離至大同國小避難所', '10/22 08:30'),
      ('0f1e2d3c4b5a6978', '重要', '大同國小避難所已開放', '10/22 07:05'),
      ('1122334455667788', '資訊', '飲用水明早送達', '10/21 22:00'),
    ]) {
      final card = find.byKey(ValueKey('admin-notice-$messageId'));
      expect(find.descendant(of: card, matching: find.text(level)), findsOneWidget, reason: content);
      expect(find.descendant(of: card, matching: find.text(content)), findsOneWidget, reason: content);
      expect(find.descendant(of: card, matching: find.textContaining(time)), findsOneWidget, reason: content);
    }
  });

  testWidgets('expired, corrected and withdrawn notices are labelled; corrected and withdrawn content is hidden',
      (tester) async {
    native.stored = [
      adminNoticeMap('1111111111111111', content: '大同國小避難所已開放', expiresAt: DateTime(2026, 10, 22, 8, 45)),
      adminNoticeMap('2222222222222222', content: '撤離至仁愛國中', status: 'corrected', replacedBy: '9999999999999999'),
      adminNoticeMap('3333333333333333', content: '全村立即撤離', status: 'withdrawn'),
      adminNoticeMap('4444444444444444', content: '飲用水明早送達'),
    ];

    await openList(tester);

    Finder cardOf(String messageId) => find.byKey(ValueKey('admin-notice-$messageId'));
    expect(find.descendant(of: cardOf('1111111111111111'), matching: find.text('已過期')), findsOneWidget);
    expect(find.text('大同國小避難所已開放'), findsOneWidget, reason: 'an expired notice is still shown');
    expect(find.descendant(of: cardOf('2222222222222222'), matching: find.text('已更正')), findsOneWidget);
    expect(find.text('撤離至仁愛國中'), findsNothing);
    expect(find.descendant(of: cardOf('3333333333333333'), matching: find.text('已撤回')), findsOneWidget);
    expect(find.text('全村立即撤離'), findsNothing);
    for (final label in ['已過期', '已更正', '已撤回']) {
      expect(find.descendant(of: cardOf('4444444444444444'), matching: find.text(label)), findsNothing,
          reason: 'a notice in force has no $label');
    }
  });

  testWidgets('opening the list marks its unread notices read, and they stay marked new while it is open',
      (tester) async {
    native.stored = [
      adminNoticeMap('1111111111111111', content: '大同國小避難所已開放'),
      adminNoticeMap('2222222222222222', content: '飲用水明早送達', read: true),
    ];

    await openList(tester);
    await tester.pump();

    expect(native.markedRead, ['1111111111111111']);
    expect(service.notices.value.unreadCount, 0);
    Finder cardOf(String messageId) => find.byKey(ValueKey('admin-notice-$messageId'));
    expect(find.descendant(of: cardOf('1111111111111111'), matching: find.text('未讀')), findsOneWidget);
    expect(find.descendant(of: cardOf('2222222222222222'), matching: find.text('未讀')), findsNothing);
  });

  testWidgets('a notice that arrives while the list is open shows up at once and is read', (tester) async {
    native.stored = [adminNoticeMap('1111111111111111', content: '大同國小避難所已開放', read: true)];
    await openList(tester);

    native.receive(adminNoticeMap('2222222222222222', content: '土石流警戒：請立即撤離', issuedAt: DateTime(2026, 10, 22, 8, 55)));
    await tester.pumpAndSettle();

    expect(find.text('土石流警戒：請立即撤離'), findsOneWidget);
    expect(native.markedRead, ['2222222222222222']);
    expect(
      tester.getTopLeft(find.text('土石流警戒：請立即撤離')).dy,
      lessThan(tester.getTopLeft(find.text('大同國小避難所已開放')).dy),
      reason: 'newest first',
    );
  });

  testWidgets('a corrected notice leads to the notice that corrected it', (tester) async {
    native.stored = [
      adminNoticeMap('9999999999999999', content: '改至仁愛國中避難', issuedAt: DateTime(2026, 10, 22, 8, 50)),
      for (var i = 0; i < 8; i++)
        adminNoticeMap('10000000000000${i}0', content: '其他公告 $i', issuedAt: DateTime(2026, 10, 22, 8, 40 - i)),
      adminNoticeMap('2222222222222222', content: '撤離至大同國小', status: 'corrected', replacedBy: '9999999999999999',
          issuedAt: DateTime(2026, 10, 22, 8)),
    ];
    await openList(tester);

    final link = find.text('查看更正後的公告');
    await tester.scrollUntilVisible(link, 200);
    expect(tester.getBottomLeft(find.text('改至仁愛國中避難')).dy, lessThan(0), reason: 'scrolled off the top');

    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('改至仁愛國中避難')).dy, greaterThanOrEqualTo(0));
  });

  testWidgets('a corrected notice whose successor is not here has no link', (tester) async {
    native.stored = [adminNoticeMap('2222222222222222', status: 'corrected', replacedBy: '9999999999999999')];

    await openList(tester);

    expect(find.text('已更正'), findsOneWidget);
    expect(find.text('查看更正後的公告'), findsNothing);
  });

  testWidgets('with no notices it says so', (tester) async {
    await openList(tester);

    expect(find.text('目前沒有公告'), findsOneWidget);
  });

  for (final screen in layoutCases) {
    testWidgets('a long notice and every label fit on $screen', (tester) async {
      useScreen(tester, screen);
      native.stored = [
        adminNoticeMap('1111111111111111', content: '土石流警戒' * 30, expiresAt: DateTime(2026, 10, 22, 8, 45)),
        adminNoticeMap('2222222222222222', status: 'corrected', replacedBy: '1111111111111111'),
        adminNoticeMap('3333333333333333', status: 'withdrawn'),
      ];

      await openList(tester);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  }
}
