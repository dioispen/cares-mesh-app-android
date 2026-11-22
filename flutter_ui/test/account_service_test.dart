import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 登出與緊急清除時，記憶體裡收到的互救任務（BLE 回報與本機進度）也要清掉；
/// Admin Notice 的收件私鑰與本機的定向公告也要刪除（#140，原生在同一個 clearKey 裡刪）。
void main() {
  late List<String> calls;

  AccountService account({Object? signOutError, Object? nativeError, Object? noticeKeyError}) => AccountService(
    signOutFirebase: () async {
      calls.add('firebase');
      if (signOutError != null) throw signOutError;
    },
    nativePanicClear: () async {
      calls.add('native');
      if (nativeError != null) throw nativeError;
    },
    clearMutualAidTasks: () => calls.add('tasks'),
    clearNoticeKey: () async {
      calls.add('noticeKey');
      if (noticeKeyError != null) throw noticeKeyError;
    },
  );

  setUp(() {
    calls = [];
    SharedPreferences.setMockInitialValues({'app_user': '{}'});
  });

  test('登出：登出 Firebase 之後刪除收件私鑰、清掉互救任務', () async {
    await account().signOut();

    expect(calls, ['firebase', 'noticeKey', 'tasks']);
  });

  test('登出：收件私鑰刪不掉也照樣登出，下次換帳號登入時原生會換掉它', () async {
    await expectLater(
      account(noticeKeyError: PlatformException(code: 'KEY_STORE_UNAVAILABLE')).signOut(),
      completes,
    );

    expect(calls, ['firebase', 'noticeKey', 'tasks']);
  });

  test('登出：沒有原生 mesh 的平台照樣登出', () async {
    await expectLater(account(noticeKeyError: MissingPluginException('no native')).signOut(), completes);

    expect(calls, ['firebase', 'noticeKey', 'tasks']);
  });

  test('緊急清除：原生清完就刪除收件私鑰並清掉，Firebase 登出失敗也已經清了', () async {
    await expectLater(account(signOutError: StateError('offline')).panicClear(), throwsA(isA<PanicSignOutFailed>()));

    expect(calls, ['native', 'noticeKey', 'tasks', 'firebase']);
  });

  test('緊急清除：原生沒清乾淨時其他東西都不動，讓使用者可以再試', () async {
    await expectLater(account(nativeError: StateError('busy')).panicClear(), throwsStateError);

    expect(calls, ['native']);
  });

  test('緊急清除：收件私鑰刪不掉時其他東西都不動，讓使用者可以再試', () async {
    await expectLater(
      account(noticeKeyError: PlatformException(code: 'KEY_STORE_UNAVAILABLE')).panicClear(),
      throwsA(isA<PlatformException>()),
    );

    expect(calls, ['native', 'noticeKey']);
  });

  test('緊急清除：本機的定向公告刪不掉時同樣中止，讓使用者可以再試', () async {
    await expectLater(
      account(noticeKeyError: PlatformException(code: 'NOTICE_STORE_UNAVAILABLE')).panicClear(),
      throwsA(isA<PlatformException>()),
    );

    expect(calls, ['native', 'noticeKey']);
  });

  test('登出：本機的定向公告刪不掉也照樣登出', () async {
    await expectLater(
      account(noticeKeyError: PlatformException(code: 'NOTICE_STORE_UNAVAILABLE')).signOut(),
      completes,
    );

    expect(calls, ['firebase', 'noticeKey', 'tasks']);
  });
}
