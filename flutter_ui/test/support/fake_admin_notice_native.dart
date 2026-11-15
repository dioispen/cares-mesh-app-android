import 'dart:async';

import 'package:flutter_ui/services/admin_notice_service.dart';

/// A notice as Kotlin `AdminNoticeBridge` sends it (`toBridgeMap`). Times are local wall-clock
/// times, so a test can name the time the screen shows.
Map<String, Object?> adminNoticeMap(
  String messageId, {
  String kind = 'broadcast',
  String level = 'urgent',
  String content = '土石流警戒：請立即撤離至大同國小避難所',
  DateTime? issuedAt,
  DateTime? expiresAt,
  String status = 'active',
  String? replacedBy,
  bool read = false,
}) {
  final issued = issuedAt ?? DateTime(2026, 10, 22, 8, 30);
  return {
    'messageId': messageId,
    'kind': kind,
    'level': level,
    'content': content,
    'issuedAt': issued.millisecondsSinceEpoch,
    'expiresAt': (expiresAt ?? issued.add(const Duration(hours: 6))).millisecondsSinceEpoch,
    'status': status,
    'replacedBy': replacedBy,
    'read': read,
  };
}

/// The native side of the Admin Notice bridge as [AdminNoticeService] reaches it, behaving as
/// Kotlin does: every change to [stored] is pushed as an `admin_notice` event with the whole list,
/// and marking a notice read is such a change.
class FakeAdminNoticeNative {
  final events = StreamController<Map<String, dynamic>>.broadcast();

  /// What `adminNotice_getAll` answers, newest first.
  List<Map<String, Object?>> stored = [];

  Object? getAllError;
  Map<String, dynamic>? systemStatus = {'type': 'system_status', 'notificationGranted': true};

  /// When false, `adminNotice_markRead` is only recorded: nothing is pushed back.
  bool pushesAfterMarkRead = true;

  final markedRead = <String>[];

  AdminNoticeService service() => AdminNoticeService(
        events: () => events.stream,
        getAll: () async {
          if (getAllError != null) throw getAllError!;
          return List.of(stored);
        },
        markRead: (messageId) async {
          markedRead.add(messageId);
          final index = stored.indexWhere((n) => n['messageId'] == messageId);
          if (!pushesAfterMarkRead || index < 0 || stored[index]['read'] == true) return;
          stored[index] = {...stored[index], 'read': true};
          push();
        },
        getSystemStatus: () async => systemStatus,
      );

  /// A notice just stored by the Inbox: newest first, then pushed.
  void receive(Map<String, Object?> notice) {
    stored = [notice, ...stored];
    push();
  }

  void push([List<Object?>? notices]) => events.add({'type': 'admin_notice', 'notices': notices ?? List.of(stored)});
}
