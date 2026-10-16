/// 設定頁列出的權限類別，對應 Kotlin `SettingsPermissionCategory`（線上名稱 [wireName]）。
enum SettingsPermissionCategory {
  location('location', '位置'),
  backgroundLocation('backgroundLocation', '背景定位'),
  nearbyDevices('nearbyDevices', '附近的裝置'),
  notifications('notifications', '通知'),
  batteryOptimization('batteryOptimization', '電池最佳化');

  const SettingsPermissionCategory(this.wireName, this.label);

  final String wireName;
  final String label;

  static SettingsPermissionCategory? fromWireName(String name) {
    for (final category in values) {
      if (category.wireName == name) return category;
    }
    return null;
  }
}

class SettingsPermissionStatus {
  const SettingsPermissionStatus(this.category, this.granted);

  final SettingsPermissionCategory category;

  /// 已允許；電池最佳化為「已排除」。
  final bool granted;
}

/// 原生 `settings_getState` 的回答（#80）：權限、藍牙、mesh 背景運作的偏好與版本號。
///
/// 每次都整份重新讀取，Dart 不自行推導：從系統設定回來（`resumed`）或系統狀態廣播時再讀一次。
class SettingsState {
  const SettingsState({
    required this.permissions,
    required this.bluetoothEnabled,
    required this.backgroundEnabled,
    required this.autoStartEnabled,
    required this.notificationAutoRestore,
    required this.appVersion,
  });

  /// 這台裝置會要求的權限，依原生的順序；這個版本不認得的類別略過。
  final List<SettingsPermissionStatus> permissions;
  final bool bluetoothEnabled;

  /// `MeshServicePreferences` 的三個開關。
  final bool backgroundEnabled;
  final bool autoStartEnabled;
  final bool notificationAutoRestore;
  final String appVersion;

  /// 缺欄位或型別不對時丟 [FormatException]，不猜預設值。
  factory SettingsState.fromMap(Map<String, dynamic> map) {
    T field<T>(String key) {
      final value = map[key];
      if (value is! T) throw FormatException('settings_getState: $key is ${value.runtimeType}, expected $T');
      return value;
    }

    return SettingsState(
      permissions: [
        for (final entry in field<List<dynamic>>('permissions').cast<Map<dynamic, dynamic>>())
          if (SettingsPermissionCategory.fromWireName(entry['category'] as String) case final category?)
            SettingsPermissionStatus(category, entry['granted'] as bool),
      ],
      bluetoothEnabled: field<bool>('bluetoothEnabled'),
      backgroundEnabled: field<bool>('backgroundEnabled'),
      autoStartEnabled: field<bool>('autoStartEnabled'),
      notificationAutoRestore: field<bool>('notificationAutoRestore'),
      appVersion: field<String>('appVersion'),
    );
  }
}
