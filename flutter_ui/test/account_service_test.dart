import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 登出與緊急清除時，記憶體裡收到的互救任務（BLE 回報與本機進度）也要清掉。
void main() {
  late List<String> calls;

  AccountService account({Object? signOutError, Object? nativeError}) => AccountService(
    signOutFirebase: () async {
      calls.add('firebase');
      if (signOutError != null) throw signOutError;
    },
    nativePanicClear: () async {
      calls.add('native');
      if (nativeError != null) throw nativeError;
    },
    clearMutualAidTasks: () => calls.add('tasks'),
  );

  setUp(() {
    calls = [];
    SharedPreferences.setMockInitialValues({'app_user': '{}'});
  });

  test('登出：登出 Firebase 之後清掉', () async {
    await account().signOut();

    expect(calls, ['firebase', 'tasks']);
  });

  test('緊急清除：原生清完就清掉，Firebase 登出失敗也已經清了', () async {
    await expectLater(account(signOutError: StateError('offline')).panicClear(), throwsA(isA<PanicSignOutFailed>()));

    expect(calls, ['native', 'tasks', 'firebase']);
  });

  test('緊急清除：原生沒清乾淨時其他東西都不動，讓使用者可以再試', () async {
    await expectLater(account(nativeError: StateError('busy')).panicClear(), throwsStateError);

    expect(calls, ['native']);
  });
}
