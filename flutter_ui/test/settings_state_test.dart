import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/settings_state.dart';

Map<String, dynamic> _stateMap({List<Map<String, dynamic>>? permissions}) => {
      'permissions': permissions ??
          [
            {'category': 'location', 'granted': true},
            {'category': 'notifications', 'granted': false},
          ],
      'bluetoothEnabled': false,
      'backgroundEnabled': true,
      'autoStartEnabled': false,
      'notificationAutoRestore': true,
      'appVersion': '2.0.2 (39)',
    };

void main() {
  test('reads the native settings_getState map', () {
    final state = SettingsState.fromMap(_stateMap());

    expect(state.permissions.map((p) => (p.category, p.granted)), [
      (SettingsPermissionCategory.location, true),
      (SettingsPermissionCategory.notifications, false),
    ]);
    expect(state.bluetoothEnabled, isFalse);
    expect(state.backgroundEnabled, isTrue);
    expect(state.autoStartEnabled, isFalse);
    expect(state.notificationAutoRestore, isTrue);
    expect(state.appVersion, '2.0.2 (39)');
  });

  test('keeps the order native lists the categories in', () {
    final state = SettingsState.fromMap(_stateMap(permissions: [
      {'category': 'batteryOptimization', 'granted': true},
      {'category': 'nearbyDevices', 'granted': true},
    ]));

    expect(state.permissions.map((p) => p.category),
        [SettingsPermissionCategory.batteryOptimization, SettingsPermissionCategory.nearbyDevices]);
  });

  test('leaves out a category this version does not know', () {
    final state = SettingsState.fromMap(_stateMap(permissions: [
      {'category': 'wifiAware', 'granted': true},
      {'category': 'location', 'granted': false},
    ]));

    expect(state.permissions.map((p) => p.category), [SettingsPermissionCategory.location]);
  });

  test('a map missing a field is a format error, not a guess', () {
    final map = _stateMap()..remove('bluetoothEnabled');

    expect(() => SettingsState.fromMap(map), throwsFormatException);
  });

  test('every category has a label and is named on the wire', () {
    for (final category in SettingsPermissionCategory.values) {
      expect(category.label, isNotEmpty);
      expect(SettingsPermissionCategory.fromWireName(category.wireName), category);
    }
  });
}
