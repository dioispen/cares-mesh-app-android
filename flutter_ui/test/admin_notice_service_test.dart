import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/admin_notice.dart';
import 'package:flutter_ui/services/admin_notice_service.dart';

/// A notice as Kotlin `AdminNoticeBridge` sends it (`toBridgeMap`).
Map<String, Object?> noticeMap(
  String messageId, {
  String level = 'urgent',
  String status = 'active',
  bool read = false,
  int issuedAt = 1792627200000,
  int expiresAt = 1792648800000,
}) =>
    {
      'messageId': messageId,
      'kind': 'broadcast',
      'level': level,
      'content': '土石流警戒：請立即撤離至大同國小避難所',
      'issuedAt': issuedAt,
      'expiresAt': expiresAt,
      'status': status,
      'replacedBy': null,
      'read': read,
    };

/// The native side of the Admin Notice bridge, as [AdminNoticeService] reaches it.
class FakeNative {
  final events = StreamController<Map<String, dynamic>>.broadcast();
  List<Object?> stored = [];
  Object? getAllError;
  Map<String, dynamic>? systemStatus = {'type': 'system_status', 'notificationGranted': true};
  final markedRead = <String>[];

  AdminNoticeService service() => AdminNoticeService(
        events: () => events.stream,
        getAll: () async {
          if (getAllError != null) throw getAllError!;
          return stored;
        },
        markRead: (messageId) async => markedRead.add(messageId),
        getSystemStatus: () async => systemStatus,
      );

  void push(List<Object?> notices) => events.add({'type': 'admin_notice', 'notices': notices});
}

void main() {
  late FakeNative native;
  late AdminNoticeService service;

  setUp(() {
    native = FakeNative();
    service = native.service();
  });

  tearDown(() => service.dispose());

  test('start reads the notices native keeps', () async {
    native.stored = [noticeMap('a1b2c3d4e5f60718'), noticeMap('0f1e2d3c4b5a6978', level: 'info', read: true)];

    await service.start();

    final notices = service.notices.value.notices;
    expect(notices.map((n) => n.messageId), ['a1b2c3d4e5f60718', '0f1e2d3c4b5a6978']);
    expect(notices.first.level, AdminNoticeLevel.urgent);
    expect(notices.first.content, '土石流警戒：請立即撤離至大同國小避難所');
    expect(notices.first.issuedAt, DateTime.utc(2026, 10, 22));
    expect(notices.first.expiresAt, DateTime.utc(2026, 10, 22, 6));
    expect(service.notices.value.unreadCount, 1);
  });

  test('an admin_notice event replaces the whole list', () async {
    native.stored = [noticeMap('a1b2c3d4e5f60718')];
    await service.start();

    native.push([noticeMap('5566778899aabbcc'), noticeMap('a1b2c3d4e5f60718', read: true)]);
    await pumpEventQueue();

    expect(service.notices.value.notices.map((n) => n.messageId), ['5566778899aabbcc', 'a1b2c3d4e5f60718']);
    expect(service.notices.value.unreadCount, 1);
  });

  test('other events and a malformed admin_notice event leave the list as it was', () async {
    native.stored = [noticeMap('a1b2c3d4e5f60718')];
    await service.start();

    native.events.add({'type': 'chat_unread', 'hasUnread': true});
    native.events.add({'type': 'admin_notice', 'notices': 'not a list'});
    await pumpEventQueue();

    expect(service.notices.value.notices.map((n) => n.messageId), ['a1b2c3d4e5f60718']);
  });

  test('a notice this version cannot read is left out, the rest are listed', () async {
    native.stored = [noticeMap('a1b2c3d4e5f60718', level: 'apocalyptic'), noticeMap('0f1e2d3c4b5a6978'), 'junk'];

    await service.start();

    expect(service.notices.value.notices.map((n) => n.messageId), ['0f1e2d3c4b5a6978']);
  });

  test('a list native cannot read leaves it empty, and later events still arrive', () async {
    native.getAllError = PlatformException(code: 'NOTICE_STORE_UNAVAILABLE');

    await service.start();
    expect(service.notices.value.notices, isEmpty);

    native.push([noticeMap('a1b2c3d4e5f60718')]);
    await pumpEventQueue();
    expect(service.notices.value.unreadCount, 1);
  });

  test('markRead hands the messageId to native and waits for its list', () async {
    native.stored = [noticeMap('a1b2c3d4e5f60718')];
    await service.start();

    await service.markRead('a1b2c3d4e5f60718');

    expect(native.markedRead, ['a1b2c3d4e5f60718']);
    expect(service.notices.value.unreadCount, 1, reason: 'native pushes the read list');
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
