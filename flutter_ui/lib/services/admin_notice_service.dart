import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bitchat_bridge.dart';
import '../models/admin_notice.dart';

/// Flutter 端的 Admin Notice 列表（#142），整個 app 只有一個：[AdminNoticeService.instance]，
/// app 一啟動就 [start]（見 `main.dart`），首頁的未讀數與列表畫面都看它。
///
/// 真相來源是原生的本機儲存（Kotlin `AdminNoticeBridge`）：這裡只保存最新一份列表，由
/// `adminNotice_getAll` 的回覆與 [AdminNoticeEvents.notices] 事件整份取代，依收到的順序套用
/// （原生在同一條執行緒上依序產生它們），不在 Dart 合併或先行修改。
///
/// 另外記著這支手機能不能跳通知（`system_status` 的 `notificationGranted`）：不能時首頁以公告卡片
/// 代替通知。
///
/// 建構子的參數只給測試注入替身，比照 `ChatService`。
class AdminNoticeService {
  AdminNoticeService({
    Stream<Map<String, dynamic>> Function()? events,
    Future<List<Object?>> Function()? getAll,
    Future<void> Function(String messageId)? markRead,
    Future<Map<String, dynamic>?> Function()? getSystemStatus,
  })  : _events = events ?? BitchatBridge.events,
        _getAll = getAll ?? BitchatBridge.getAdminNotices,
        _markRead = markRead ?? BitchatBridge.markAdminNoticeRead,
        _getSystemStatus = getSystemStatus ?? BitchatBridge.getSystemStatus;

  static final AdminNoticeService instance = AdminNoticeService();

  final Stream<Map<String, dynamic>> Function() _events;
  final Future<List<Object?>> Function() _getAll;
  final Future<void> Function(String messageId) _markRead;
  final Future<Map<String, dynamic>?> Function() _getSystemStatus;

  final ValueNotifier<AdminNoticeList> _notices = ValueNotifier(AdminNoticeList.empty);
  final ValueNotifier<bool?> _notificationsAllowed = ValueNotifier(null);

  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// 這支手機保留的所有公告，新的在前；原生回報前是空的。
  ValueListenable<AdminNoticeList> get notices => _notices;

  /// 這支手機能不能跳出公告通知；原生回報前（或沒有原生的平台）是 null。
  ValueListenable<bool?> get notificationsAllowed => _notificationsAllowed;

  /// 開始接收公告。可重複呼叫，只有第一次有效。先訂閱事件，再讀列表，中間到的公告不會漏掉。
  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = _events().listen(
      _handleEvent,
      onError: (Object error) => debugPrint('AdminNoticeService: event stream error: $error'),
    );
    await refresh();
  }

  /// 重讀列表與通知權限，例如回到 App 時：權限是在系統設定裡改的，原生不會為它推事件；
  /// 列表也順便讓過了保留期的公告消失。讀不到時留著原本的值。
  Future<void> refresh() async {
    await Future.wait([_readList(), _readNotificationsAllowed()]);
  }

  /// 使用者在 App 裡讀了這則公告。列表不在這裡先改，等原生推來新的列表。bridge 錯誤會往上拋。
  Future<void> markRead(String messageId) => _markRead(messageId);

  Future<void> _readList() async {
    try {
      _replaceList(AdminNoticeList.fromList(await _getAll()));
    } catch (e) {
      // 沒有原生（iOS、測試），或原生的儲存讀不到；之後的事件照樣會送達。
      debugPrint('AdminNoticeService: reading the notices failed: $e');
    }
  }

  Future<void> _readNotificationsAllowed() async {
    try {
      _applySystemStatus(await _getSystemStatus());
    } catch (e) {
      debugPrint('AdminNoticeService: reading the system status failed: $e');
    }
  }

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case AdminNoticeEvents.notices:
        _replaceList(AdminNoticeList.fromList(event['notices']));
      case 'system_status':
        _applySystemStatus(event);
    }
  }

  void _replaceList(AdminNoticeList? list) {
    if (list == null) {
      debugPrint('AdminNoticeService: ignoring a malformed notice list');
      return;
    }
    _notices.value = list;
  }

  void _applySystemStatus(Map<String, dynamic>? status) {
    final granted = status?['notificationGranted'];
    if (granted is bool) _notificationsAllowed.value = granted;
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _notices.dispose();
    _notificationsAllowed.dispose();
  }
}
