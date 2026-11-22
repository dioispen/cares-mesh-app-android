import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/admin_notice.dart';
import 'package:flutter_ui/services/admin_notice_service.dart';

import 'support/fake_admin_notice_native.dart';

/// [AdminNoticeService] (#142): the notice list as native keeps and pushes it, and whether this
/// phone may post notifications.
void main() {
  late FakeAdminNoticeNative native;
  late AdminNoticeService service;

  setUp(() {
    native = FakeAdminNoticeNative();
    service = native.service();
  });

  tearDown(() => service.dispose());

  List<String> listedIds() => service.notices.value.notices.map((n) => n.messageId).toList();

  test('start reads the notices native keeps', () async {
    native.stored = [
      {
        'messageId': 'a1b2c3d4e5f60718',
        'kind': 'broadcast',
        'level': 'urgent',
        'content': '土石流警戒：請立即撤離至大同國小避難所',
        'issuedAt': 1792627200000,
        'expiresAt': 1792648800000,
        'status': 'active',
        'replacedBy': null,
        'read': false,
      },
      adminNoticeMap('0f1e2d3c4b5a6978', kind: 'targeted', level: 'info', status: 'corrected', replacedBy: '5566778899aabbcc', read: true),
    ];

    await service.start();

    final [first, second] = service.notices.value.notices;
    expect(first.messageId, 'a1b2c3d4e5f60718');
    expect(first.kind, AdminNoticeKind.broadcast);
    expect(first.level, AdminNoticeLevel.urgent);
    expect(first.content, '土石流警戒：請立即撤離至大同國小避難所');
    expect(first.issuedAt, DateTime.utc(2026, 10, 22));
    expect(first.expiresAt, DateTime.utc(2026, 10, 22, 6));
    expect(first.status, AdminNoticeStatus.active);
    expect(first.read, isFalse);
    expect(second.kind, AdminNoticeKind.targeted);
    expect(second.level, AdminNoticeLevel.info);
    expect(second.status, AdminNoticeStatus.corrected);
    expect(second.replacedBy, '5566778899aabbcc');
    expect(service.notices.value.unreadCount, 1);
  });

  test('an admin_notice event replaces the whole list', () async {
    native.stored = [adminNoticeMap('a1b2c3d4e5f60718')];
    await service.start();

    native.push([adminNoticeMap('5566778899aabbcc'), adminNoticeMap('a1b2c3d4e5f60718', read: true)]);
    await pumpEventQueue();

    expect(listedIds(), ['5566778899aabbcc', 'a1b2c3d4e5f60718']);
    expect(service.notices.value.unreadCount, 1);
  });

  test('other events and a malformed admin_notice event leave the list as it was', () async {
    native.stored = [adminNoticeMap('a1b2c3d4e5f60718')];
    await service.start();

    native.events.add({'type': 'chat_unread', 'hasUnread': true});
    native.events.add({'type': 'admin_notice', 'notices': 'not a list'});
    await pumpEventQueue();

    expect(listedIds(), ['a1b2c3d4e5f60718']);
  });

  test('a notice this version cannot read is left out, the rest are listed', () async {
    native.stored = [adminNoticeMap('a1b2c3d4e5f60718', level: 'apocalyptic'), adminNoticeMap('0f1e2d3c4b5a6978'), {'junk': true}];

    await service.start();

    expect(listedIds(), ['0f1e2d3c4b5a6978']);
  });

  test('a list native cannot read leaves it empty, and later events still arrive', () async {
    native.getAllError = PlatformException(code: 'NOTICE_STORE_UNAVAILABLE');

    await service.start();
    expect(service.notices.value.notices, isEmpty);

    native.receive(adminNoticeMap('a1b2c3d4e5f60718'));
    await pumpEventQueue();
    expect(service.notices.value.unreadCount, 1);
  });

  test('markRead hands the messageId to native and waits for its list', () async {
    native
      ..stored = [adminNoticeMap('a1b2c3d4e5f60718')]
      ..pushesAfterMarkRead = false;
    await service.start();

    await service.markRead('a1b2c3d4e5f60718');

    expect(native.markedRead, ['a1b2c3d4e5f60718']);
    expect(service.notices.value.unreadCount, 1, reason: 'not changed before native pushes the read list');
  });

  test('whether notifications are allowed comes from the system status', () async {
    native.systemStatus = {'type': 'system_status', 'notificationGranted': false};
    expect(service.notificationsAllowed.value, isNull, reason: 'unknown before native answers');

    await service.start();
    expect(service.notificationsAllowed.value, isFalse);

    native.systemStatus = {'type': 'system_status', 'notificationGranted': true};
    await service.refresh();
    expect(service.notificationsAllowed.value, isTrue);

    native.events.add({'type': 'system_status', 'notificationGranted': false});
    await pumpEventQueue();
    expect(service.notificationsAllowed.value, isFalse);
  });

  test('without a native system status it stays unknown', () async {
    native.systemStatus = null;

    await service.start();

    expect(service.notificationsAllowed.value, isNull);
  });
}
