import '../bridge/bitchat_bridge.dart';
import '../models/settings_state.dart';

/// 設定頁和原生之間的薄層（#80）：讀取 [SettingsState]、轉交使用者的動作。
///
/// 真相來源是原生（`PermissionManager`、`MeshServicePreferences`），這裡不保存狀態；bridge 錯誤
/// 一律往上拋，由畫面告訴使用者。建構子的參數只給測試注入替身，比照 `ChatService`。
class SettingsService {
  SettingsService({
    Future<Map<String, dynamic>> Function()? getState,
    Future<String?> Function(String category)? requestPermission,
    Future<void> Function()? requestEnableBluetooth,
    Future<void> Function(bool enabled)? setBackgroundEnabled,
    Future<void> Function(bool enabled)? setAutoStartEnabled,
    Future<void> Function(bool enabled)? setNotificationAutoRestore,
    Stream<Map<String, dynamic>> Function()? events,
  })  : _getState = getState ?? BitchatBridge.getSettingsState,
        _requestPermission = requestPermission ?? BitchatBridge.requestSettingsPermission,
        _requestEnableBluetooth = requestEnableBluetooth ?? BitchatBridge.requestEnableBluetooth,
        _setBackgroundEnabled = setBackgroundEnabled ?? BitchatBridge.setBackgroundEnabled,
        _setAutoStartEnabled = setAutoStartEnabled ?? BitchatBridge.setAutoStartEnabled,
        _setNotificationAutoRestore = setNotificationAutoRestore ?? BitchatBridge.setNotificationAutoRestore,
        _events = events ?? BitchatBridge.events;

  final Future<Map<String, dynamic>> Function() _getState;
  final Future<String?> Function(String category) _requestPermission;
  final Future<void> Function() _requestEnableBluetooth;
  final Future<void> Function(bool enabled) _setBackgroundEnabled;
  final Future<void> Function(bool enabled) _setAutoStartEnabled;
  final Future<void> Function(bool enabled) _setNotificationAutoRestore;
  final Stream<Map<String, dynamic>> Function() _events;

  Future<SettingsState> loadState() async => SettingsState.fromMap(await _getState());

  /// 還沒允許：系統詢問；已允許或系統不再詢問：App 資訊頁。結果在回到 App 時重新讀取。
  Future<void> requestPermission(SettingsPermissionCategory category) => _requestPermission(category.wireName);

  Future<void> requestEnableBluetooth() => _requestEnableBluetooth();

  Future<void> setBackgroundEnabled(bool enabled) => _setBackgroundEnabled(enabled);

  Future<void> setAutoStartEnabled(bool enabled) => _setAutoStartEnabled(enabled);

  Future<void> setNotificationAutoRestore(bool enabled) => _setNotificationAutoRestore(enabled);

  /// 系統藍牙或定位狀態改變（原生 `statusReceiver` 推的 `system_status`）。
  Stream<void> get systemStatusChanges =>
      _events().where((event) => event['type'] == 'system_status').map((_) {});
}
