import 'package:flutter/foundation.dart' show debugPrint, immutable;

/// Admin Notice 的等級（docs/ADMIN_NOTICE_V1.md「Payload」的 level），[wire] 是 Kotlin
/// `AdminNoticeBridge` 送來的名稱。
enum AdminNoticeLevel {
  info('info', '資訊'),
  important('important', '重要'),
  urgent('urgent', '緊急');

  const AdminNoticeLevel(this.wire, this.label);

  final String wire;

  /// 列表與首頁卡片上的等級名稱，與通知的 channel 名稱一致。
  final String label;

  static AdminNoticeLevel? fromWire(Object? value) => values.where((l) => l.wire == value).firstOrNull;
}

/// 廣播給所有人，或定向給幾個收件裝置（內容只有它們解得開）。
enum AdminNoticeKind {
  broadcast('broadcast'),
  targeted('targeted');

  const AdminNoticeKind(this.wire);

  final String wire;

  static AdminNoticeKind? fromWire(Object? value) => values.where((k) => k.wire == value).firstOrNull;
}

/// 公告目前的狀態（docs/ADMIN_NOTICE_V1.md「撤回與取代」）。「已過期」不在這裡：它看時間，見
/// [AdminNotice.isExpiredAt]。
enum AdminNoticeStatus {
  /// 照收到時的內容顯示。
  active('active'),

  /// 已更正：較新的一則（[AdminNotice.replacedBy]）取代了它，原內容不再顯示。
  corrected('corrected'),

  /// 已撤回：原內容不再顯示。
  withdrawn('withdrawn');

  const AdminNoticeStatus(this.wire);

  final String wire;

  static AdminNoticeStatus? fromWire(Object? value) => values.where((s) => s.wire == value).firstOrNull;
}

/// 這支手機收到的一則 Admin Notice，原生本機儲存的投影（`adminNotice_getAll` 的一列）。
@immutable
class AdminNotice {
  const AdminNotice({
    required this.messageId,
    required this.kind,
    required this.level,
    required this.content,
    required this.issuedAt,
    required this.expiresAt,
    required this.status,
    required this.replacedBy,
    required this.read,
  });

  final String messageId;
  final AdminNoticeKind kind;
  final AdminNoticeLevel level;

  /// 公告的文字；[status] 不是 [AdminNoticeStatus.active] 時畫面不顯示它。
  final String content;

  /// Administrator 發出的時間（UTC）。
  final DateTime issuedAt;

  /// 有效期限（UTC）。過了就標示「已過期」，再過 7 天原生就把它刪掉。
  final DateTime expiresAt;

  final AdminNoticeStatus status;

  /// 更正它的那則公告的 messageId（[AdminNoticeStatus.corrected]），其餘為 null。
  final String? replacedBy;

  /// 使用者在 App 裡讀過了。
  final bool read;

  bool get isActive => status == AdminNoticeStatus.active;

  /// [now] 時是否已過期（過了 expiresAt）。
  bool isExpiredAt(DateTime now) => now.isAfter(expiresAt);

  /// 原生送來的一則；缺欄位或有這版不認得的值時為 null。
  static AdminNotice? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final messageId = raw['messageId'];
    final kind = AdminNoticeKind.fromWire(raw['kind']);
    final level = AdminNoticeLevel.fromWire(raw['level']);
    final content = raw['content'];
    final issuedAt = raw['issuedAt'];
    final expiresAt = raw['expiresAt'];
    final status = AdminNoticeStatus.fromWire(raw['status']);
    final replacedBy = raw['replacedBy'];
    final read = raw['read'];
    if (messageId is! String ||
        kind == null ||
        level == null ||
        content is! String ||
        issuedAt is! int ||
        expiresAt is! int ||
        status == null ||
        (replacedBy != null && replacedBy is! String) ||
        read is! bool) {
      return null;
    }
    return AdminNotice(
      messageId: messageId,
      kind: kind,
      level: level,
      content: content,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAt, isUtc: true),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true),
      status: status,
      replacedBy: replacedBy as String?,
      read: read,
    );
  }
}

/// 整份公告列表，新的在前，順序照原生。
@immutable
class AdminNoticeList {
  const AdminNoticeList(this.notices);

  static const empty = AdminNoticeList([]);

  final List<AdminNotice> notices;

  /// 還沒在 App 裡讀過的則數，首頁顯示的未讀數。已過期、已更正、已撤回的也算：使用者還沒看過。
  int get unreadCount => notices.where((n) => !n.read).length;

  /// 首頁卡片（沒有通知權限時代替通知）要顯示的那則：最新一則未讀、仍有效、沒被更正或撤回的公告。
  AdminNotice? latestUnreadInForce(DateTime now) =>
      notices.where((n) => !n.read && n.isActive && !n.isExpiredAt(now)).firstOrNull;

  AdminNotice? byId(String messageId) => notices.where((n) => n.messageId == messageId).firstOrNull;

  /// 原生送來的列表；不是 list 時為 null。這版讀不懂的那幾則略過，其餘照列。
  static AdminNoticeList? fromList(Object? raw) {
    if (raw is! List) return null;
    final notices = <AdminNotice>[];
    for (final entry in raw) {
      final notice = AdminNotice.fromMap(entry);
      if (notice == null) {
        // Not the entry itself: a targeted notice's content must not end up in the log.
        final id = entry is Map ? entry['messageId'] : null;
        debugPrint('AdminNoticeList: skipping an unreadable notice ${id ?? '(no messageId)'}');
      } else {
        notices.add(notice);
      }
    }
    return AdminNoticeList(List.unmodifiable(notices));
  }
}
