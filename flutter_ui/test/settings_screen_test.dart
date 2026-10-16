import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/screens/settings_screen.dart';
import 'package:flutter_ui/services/account_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';
import 'package:flutter_ui/services/profile_store.dart';
import 'package:flutter_ui/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppUser _user() => AppUser(
      id: 'uid-1234',
      email: 'a@example.com',
      name: '王小明',
      phone: '0912-345-678',
      area: '南投縣埔里鎮',
      emergencyContactName: '王大明',
      emergencyContactPhone: '0923-456-789',
      emergencyContactRelation: '父親',
      bloodType: 'O 型',
      medicalInfo: '青黴素過敏',
      registeredAt: DateTime.utc(2026, 1, 2),
      avatar: 'cat',
    );

/// What native answers `settings_getState` with; tests change it between reads.
class _Native {
  List<Map<String, dynamic>> permissions = [
    {'category': 'location', 'granted': true},
    {'category': 'backgroundLocation', 'granted': false},
    {'category': 'nearbyDevices', 'granted': true},
    {'category': 'notifications', 'granted': false},
    {'category': 'batteryOptimization', 'granted': true},
  ];
  bool bluetoothEnabled = true;
  bool backgroundEnabled = true;
  bool autoStartEnabled = true;
  bool notificationAutoRestore = false;
  Object? stateError;
  int stateReads = 0;
  final calls = <String>[];
  final events = StreamController<Map<String, dynamic>>.broadcast();

  SettingsService service() => SettingsService(
        getState: () async {
          stateReads++;
          if (stateError != null) throw stateError!;
          return {
            'permissions': permissions,
            'bluetoothEnabled': bluetoothEnabled,
            'backgroundEnabled': backgroundEnabled,
            'autoStartEnabled': autoStartEnabled,
            'notificationAutoRestore': notificationAutoRestore,
            'appVersion': '2.0.2 (39)',
          };
        },
        requestPermission: (category) async {
          calls.add('requestPermission:$category');
          return 'prompted';
        },
        requestEnableBluetooth: () async => calls.add('requestEnableBluetooth'),
        setBackgroundEnabled: (enabled) async {
          calls.add('setBackgroundEnabled:$enabled');
          backgroundEnabled = enabled;
        },
        setAutoStartEnabled: (enabled) async {
          calls.add('setAutoStartEnabled:$enabled');
          autoStartEnabled = enabled;
        },
        setNotificationAutoRestore: (enabled) async {
          calls.add('setNotificationAutoRestore:$enabled');
          notificationAutoRestore = enabled;
        },
        events: () => events.stream,
      );
}

void main() {
  // A tap that misses the widget it was aimed at fails the test instead of passing silently.
  WidgetController.hitTestWarningShouldBeFatal = true;

  late _Native native;
  late List<Map<String, Object?>> remoteWrites;
  late Completer<void> remote;
  late List<String> account;
  late Future<void> Function() nativePanic;
  late Future<void> Function() firebaseSignOut;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'app_user': jsonEncode(_user().toJson()),
      'pending_app_user': jsonEncode(_user().toJson()),
      'unrelated': 'kept',
    });
    mascotEnabledNotifier.value = true;
    native = _Native();
    remoteWrites = [];
    account = [];
    nativePanic = () async => account.add('nativePanic');
    firebaseSignOut = () async => account.add('firebaseSignOut');
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        user: _user(),
        settings: native.service(),
        profiles: ProfileStore(writeRemote: (uid, fields) {
          remoteWrites.add(fields);
          // Made here, inside the test's fake async zone, so completing it is seen by pump.
          remote = Completer<void>();
          return remote.future;
        }),
        account: AccountService(
          signOutFirebase: () => firebaseSignOut(),
          nativePanicClear: () => nativePanic(),
        ),
        signedOutBuilder: (_) => const Scaffold(body: Text('login screen')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    // As the user closing the keyboard: a focused field would keep scrolling its caret back.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
    // Found in the list's cache extent is not on screen yet.
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapOn(WidgetTester tester, Finder finder) async {
    await scrollTo(tester, finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder rowFor(String label) => find.ancestor(of: find.text(label), matching: find.byType(ListTile)).first;

  group('the profile card', () {
    testWidgets('shows the avatar, name and user ID', (tester) async {
      await pumpSettings(tester);

      expect(find.text('王小明'), findsWidgets);
      expect(find.text('uid-1234'), findsWidgets);
    });

    testWidgets('copies the user ID when tapped', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(const Key('settings_copy_user_id')));
      await tester.pump();

      expect(find.text('User ID 已複製'), findsOneWidget);
    });
  });

  group('permissions and system', () {
    testWidgets('each category says whether it is allowed', (tester) async {
      await pumpSettings(tester);

      expect(find.descendant(of: rowFor('位置'), matching: find.text('已允許')), findsOneWidget);
      expect(find.descendant(of: rowFor('背景定位'), matching: find.text('未允許')), findsOneWidget);
      expect(find.descendant(of: rowFor('附近的裝置'), matching: find.text('已允許')), findsOneWidget);
      await scrollTo(tester, find.text('電池最佳化'));
      expect(find.descendant(of: rowFor('通知'), matching: find.text('未允許')), findsOneWidget);
      expect(find.descendant(of: rowFor('電池最佳化'), matching: find.text('已排除')), findsOneWidget);
    });

    testWidgets('tapping a category hands it to native', (tester) async {
      await pumpSettings(tester);

      await tapOn(tester, rowFor('背景定位'));

      expect(native.calls, ['requestPermission:backgroundLocation']);
    });

    testWidgets('are read again when the app comes back from the system settings', (tester) async {
      await pumpSettings(tester);
      final reads = native.stateReads;
      native.permissions = [
        {'category': 'location', 'granted': false},
      ];

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(native.stateReads, reads + 1);
      expect(find.descendant(of: rowFor('位置'), matching: find.text('未允許')), findsOneWidget);
    });

    testWidgets('Bluetooth follows the system status broadcast', (tester) async {
      await pumpSettings(tester);
      expect(find.descendant(of: rowFor('藍牙'), matching: find.text('已開啟')), findsOneWidget);
      expect(find.text('開啟藍牙'), findsNothing);

      native.bluetoothEnabled = false;
      native.events.add({'type': 'system_status', 'bluetoothEnabled': false});
      await tester.pumpAndSettle();

      expect(find.descendant(of: rowFor('藍牙'), matching: find.text('已關閉')), findsOneWidget);
      await tapOn(tester, find.text('開啟藍牙'));
      expect(native.calls, ['requestEnableBluetooth']);
    });

    testWidgets('a failing status event stream is shown, not dropped', (tester) async {
      await pumpSettings(tester);

      native.events.addError(MissingPluginException('no event channel'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no event channel'), findsOneWidget);
    });

    testWidgets('a native read that fails says so instead of showing nothing', (tester) async {
      native.stateError = MissingPluginException('no native settings');

      await pumpSettings(tester);

      expect(find.textContaining('無法讀取系統狀態'), findsOneWidget);
      expect(find.textContaining('no native settings'), findsOneWidget);
    });
  });

  group('mesh background', () {
    testWidgets('switching background off tells native and hides auto-restore', (tester) async {
      await pumpSettings(tester);
      await scrollTo(tester, find.text('常駐通知被滑掉時立即恢復'));

      await tapOn(tester, find.widgetWithText(SwitchListTile, '背景執行'));

      expect(native.calls, ['setBackgroundEnabled:false']);
      expect(find.text('常駐通知被滑掉時立即恢復'), findsNothing);
    });

    testWidgets('auto start and auto-restore are handed to native', (tester) async {
      await pumpSettings(tester);

      await tapOn(tester, find.widgetWithText(SwitchListTile, '開機自動啟動'));
      await tapOn(tester, find.widgetWithText(SwitchListTile, '常駐通知被滑掉時立即恢復'));

      expect(native.calls, ['setAutoStartEnabled:false', 'setNotificationAutoRestore:true']);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '常駐通知被滑掉時立即恢復')).value, isTrue);
    });
  });

  group('the profile', () {
    Future<void> startEditing(WidgetTester tester) async {
      await tapOn(tester, find.text('編輯個人資料'));
    }

    Future<void> save(WidgetTester tester) => tapOn(tester, find.text('儲存'));

    testWidgets('shows e-mail and user ID read-only next to the editable fields', (tester) async {
      await pumpSettings(tester);
      await startEditing(tester);

      expect(find.widgetWithText(TextFormField, '姓名'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Email'), findsNothing);
      expect(find.text('a@example.com'), findsOneWidget);
    });

    testWidgets('an edit is saved on this device and in Firestore, and says when it is not synced yet',
        (tester) async {
      await pumpSettings(tester);
      await startEditing(tester);

      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '王小華');
      await save(tester);

      final prefs = await SharedPreferences.getInstance();
      expect((jsonDecode(prefs.getString('app_user')!) as Map)['name'], '王小華');
      expect(remoteWrites.single['name'], '王小華');
      expect(find.textContaining('尚未同步'), findsOneWidget);

      remote.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未同步'), findsNothing);
      expect(find.textContaining('已同步'), findsOneWidget);
    });

    testWidgets('a failed sync is reported', (tester) async {
      await pumpSettings(tester);
      await startEditing(tester);
      await save(tester);

      remote.completeError(FirebaseLikeException('permission-denied'));
      await tester.pumpAndSettle();

      expect(find.textContaining('同步失敗'), findsOneWidget);
    });

    testWidgets('fields are checked as registration checks them', (tester) async {
      await pumpSettings(tester);
      await startEditing(tester);

      await tester.enterText(find.widgetWithText(TextFormField, '手機號碼'), '0912');
      await save(tester);

      expect(find.text('手機號碼格式不正確'), findsOneWidget);
      expect(remoteWrites, isEmpty);
    });

    testWidgets('cancelling leaves the profile as it was', (tester) async {
      await pumpSettings(tester);
      await startEditing(tester);

      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '王小華');
      await tapOn(tester, find.text('取消'));

      expect(find.text('王小華'), findsNothing);
      expect(remoteWrites, isEmpty);
    });
  });

  testWidgets('the assistant switch takes effect at once and is remembered', (tester) async {
    await pumpSettings(tester);
    await tapOn(tester, find.widgetWithText(SwitchListTile, '顯示小助理'));

    expect(mascotEnabledNotifier.value, isFalse);
    expect((await SharedPreferences.getInstance()).getBool(mascotEnabledPrefsKey), isFalse);
  });

  group('account and data', () {
    testWidgets('logging out signs out of Firebase, forgets the profile and goes to login', (tester) async {
      await pumpSettings(tester);
      await tapOn(tester, find.text('登出'));
      await tester.tap(find.widgetWithText(TextButton, '登出'));
      await tester.pumpAndSettle();

      expect(account, ['firebaseSignOut']);
      expect((await SharedPreferences.getInstance()).getString('app_user'), isNull);
      expect(find.text('login screen'), findsOneWidget);
    });

    Future<void> openPanicDialog(WidgetTester tester) async {
      await tapOn(tester, find.text('緊急清除資料'));
    }

    Finder confirmButton() => find.widgetWithText(FilledButton, '清除');

    testWidgets('panic clear waits until 清除 is typed', (tester) async {
      await pumpSettings(tester);
      await openPanicDialog(tester);

      expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, '清');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNull);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(account, isEmpty);
    });

    testWidgets('panic clear wipes native data, the stored profile and the sign-in, then goes to login',
        (tester) async {
      await pumpSettings(tester);
      await openPanicDialog(tester);

      await tester.enterText(find.byType(TextField).last, '清除');
      await tester.pump();
      await tester.tap(confirmButton());
      await tester.pumpAndSettle();

      expect(account, ['nativePanic', 'firebaseSignOut']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_user'), isNull);
      expect(prefs.getString('pending_app_user'), isNull);
      expect(prefs.getString('unrelated'), 'kept');
      expect(find.text('login screen'), findsOneWidget);
    });

    testWidgets('a sign-out failing after the wipe says the data is gone and still leaves for login',
        (tester) async {
      firebaseSignOut = () async => throw StateError('network');
      await pumpSettings(tester);
      await openPanicDialog(tester);

      await tester.enterText(find.byType(TextField).last, '清除');
      await tester.pump();
      await tester.tap(confirmButton());
      await tester.pumpAndSettle();

      expect(find.text('資料已清除'), findsOneWidget);
      expect(find.textContaining('清除未完成'), findsNothing);
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      expect(account, ['nativePanic']);
      expect(find.text('login screen'), findsOneWidget);
    });

    testWidgets('a native wipe that fails is reported and nothing else is cleared', (tester) async {
      nativePanic = () async => throw PlatformException(code: 'PANIC_INCOMPLETE', message: 'db');
      await pumpSettings(tester);
      await openPanicDialog(tester);

      await tester.enterText(find.byType(TextField).last, '清除');
      await tester.pump();
      await tester.tap(confirmButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('清除未完成'), findsOneWidget);
      expect(account, isEmpty);
      expect((await SharedPreferences.getInstance()).getString('app_user'), isNotNull);
      expect(find.text('login screen'), findsNothing);
    });
  });

  testWidgets('about shows the version', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, find.text('2.0.2 (39)'));

    expect(find.text('2.0.2 (39)'), findsOneWidget);
  });

  group('fits a small phone at 1.3× text', () {
    Future<void> pumpSmall(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpSettings(tester);
    }

    testWidgets('viewing', (tester) async {
      await pumpSmall(tester);
      await scrollTo(tester, find.text('2.0.2 (39)'));

      expect(tester.takeException(), isNull);
    });

    testWidgets('editing the profile', (tester) async {
      await pumpSmall(tester);
      await tapOn(tester, find.text('編輯個人資料'));
      await scrollTo(tester, find.text('2.0.2 (39)'));

      expect(tester.takeException(), isNull);
    });
  });
}

/// Stands in for a FirebaseException without needing Firebase.
class FirebaseLikeException implements Exception {
  FirebaseLikeException(this.code);
  final String code;

  @override
  String toString() => 'FirebaseLikeException($code)';
}
