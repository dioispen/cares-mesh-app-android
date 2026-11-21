import '../bridge/bitchat_bridge.dart';
import '../models/background_operation.dart';

/// 首頁背景運作提示（P1-6）和原生之間的薄層。
///
/// 狀態來自原生的 `system_status`（`getSystemStatus` 與事件串流），這裡不保存狀態；修正動作沿用
/// 既有的 bridge method，錯誤一律往上拋，由畫面告訴使用者。建構子的參數只給測試注入替身。
class BackgroundOperationService {
  BackgroundOperationService({
    Future<Map<String, dynamic>?> Function()? getSystemStatus,
    Stream<Map<String, dynamic>> Function()? events,
    Future<void> Function(bool enabled)? setBackgroundEnabled,
    Future<void> Function(String category)? requestSettingsPermission,
    Future<void> Function()? requestPermissions,
    Future<void> Function()? startMesh,
  })  : _getSystemStatus = getSystemStatus ?? BitchatBridge.getSystemStatus,
        _events = events ?? BitchatBridge.events,
        _setBackgroundEnabled = setBackgroundEnabled ?? BitchatBridge.setBackgroundEnabled,
        _requestSettingsPermission = requestSettingsPermission ?? BitchatBridge.requestSettingsPermission,
        _requestPermissions = requestPermissions ?? BitchatBridge.requestPermissions,
        _startMesh = startMesh ?? BitchatBridge.startMesh;

  final Future<Map<String, dynamic>?> Function() _getSystemStatus;
  final Stream<Map<String, dynamic>> Function() _events;
  final Future<void> Function(bool enabled) _setBackgroundEnabled;
  final Future<void> Function(String category) _requestSettingsPermission;
  final Future<void> Function() _requestPermissions;
  final Future<void> Function() _startMesh;

  /// 目前的狀態；沒有原生實作，或原生沒有回報背景運作時為 null。
  Future<BackgroundOperationStatus?> load() async {
    final status = await _getSystemStatus();
    return status == null ? null : BackgroundOperationStatus.fromSystemStatus(status);
  }

  /// 原生每次推 `system_status`（藍牙、定位、前景服務狀態改變）時的新狀態。
  Stream<BackgroundOperationStatus?> get changes => _events()
      .where((event) => event['type'] == 'system_status')
      .map(BackgroundOperationStatus.fromSystemStatus);

  /// 執行提示上的修正動作；結果之後由 [changes] 或重新 [load] 得知。
  Future<void> fix(BackgroundOperationStatus status) async {
    switch (backgroundNoticeFor(status)?.action) {
      case BackgroundNoticeAction.enableBackground:
        await _setBackgroundEnabled(true);
      case BackgroundNoticeAction.requestPermission:
        final category = status.missingPermission;
        if (category != null) {
          await _requestSettingsPermission(category.wireName);
        } else {
          await _requestPermissions();
        }
      case BackgroundNoticeAction.restartService:
        await _startMesh();
      case null:
        break;
    }
  }
}
