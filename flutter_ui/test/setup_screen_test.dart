import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart' show SettingsMethods;
import 'package:flutter_ui/screens/setup_screen.dart';

/// The setup screen tells the user why the native side could not start (#71), instead of one
/// fixed text for every failure.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Answers each method from [replies]; a method not listed has no native implementation.
  void native(Map<String, Object? Function()> replies) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final reply = replies[call.method];
      if (reply == null) throw MissingPluginException();
      return reply();
    });
  }

  Future<void> pumpSetup(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SetupScreen()));
    // The spinner never settles; a few frames are enough for the bridge calls to answer.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  testWidgets('a native startMesh failure shows the reason Kotlin reported', (tester) async {
    native({
      'checkPermissions': () => true,
      'startMesh': () => throw PlatformException(code: 'START_FAILED', message: 'Bluetooth adapter is off'),
    });

    await pumpSetup(tester);

    expect(find.textContaining('啟動 Mesh 失敗'), findsOneWidget);
    expect(find.textContaining('Bluetooth adapter is off'), findsOneWidget);
    expect(find.text('重新檢查並啟動'), findsOneWidget);
  });

  testWidgets('a native startMesh failure without a reason shows its code', (tester) async {
    native({
      'checkPermissions': () => true,
      'startMesh': () => throw PlatformException(code: 'START_FAILED'),
    });

    await pumpSetup(tester);

    expect(find.textContaining('START_FAILED'), findsOneWidget);
  });

  testWidgets('without a native mesh it says so instead of blaming Bluetooth', (tester) async {
    native({'checkPermissions': () => true});

    await pumpSetup(tester);

    expect(find.textContaining('啟動 Mesh 失敗'), findsOneWidget);
    expect(find.textContaining('沒有原生 Mesh 服務'), findsOneWidget);
    expect(find.textContaining('請確認藍牙已開啟'), findsNothing);
  });

  testWidgets('a native checkPermissions failure is reported, not taken as missing permissions', (tester) async {
    native({'checkPermissions': () => throw PlatformException(code: 'CHECK_FAILED', message: 'permission service died')});

    await pumpSetup(tester);

    expect(find.textContaining('permission service died'), findsOneWidget);
    expect(find.text('授權權限'), findsNothing);
  });

  testWidgets('when the permission request cannot be shown, the user sees why', (tester) async {
    native({
      'checkPermissions': () => false,
      'requestPermissions': () =>
          throw PlatformException(code: 'NO_ACTIVITY', message: 'Cannot request permissions without an activity'),
    });

    await pumpSetup(tester);

    expect(find.textContaining('Cannot request permissions without an activity'), findsOneWidget);
    expect(find.text('授權權限'), findsOneWidget);
  });

  testWidgets('the 授權權限 button reports a refused permission request too', (tester) async {
    var refuse = false;
    native({
      'checkPermissions': () => false,
      'requestPermissions': () => refuse ? throw PlatformException(code: 'NO_ACTIVITY', message: 'no activity now') : true,
    });
    await pumpSetup(tester);
    expect(find.textContaining('no activity now'), findsNothing);

    refuse = true;
    await tester.tap(find.text('授權權限'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('no activity now'), findsOneWidget);
  });

  testWidgets('coming back to the app re-checks permissions without asking again', (tester) async {
    // A permission denied for good: the system answers at once without a prompt, and the app
    // pauses and resumes. Asking again on every resume looped forever and made the screen flicker.
    var checks = 0;
    var requests = 0;
    native({
      'checkPermissions': () {
        checks++;
        return false;
      },
      'requestPermissions': () {
        requests++;
        return true;
      },
    });
    await pumpSetup(tester);
    expect(requests, 1);

    for (var i = 0; i < 3; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
    }

    expect(checks, 4);
    expect(requests, 1);
    expect(find.text('授權權限'), findsOneWidget);
  });

  testWidgets('前往系統設定 opens the app settings for permissions the system no longer asks for', (tester) async {
    var opened = 0;
    native({
      'checkPermissions': () => false,
      'requestPermissions': () => true,
      SettingsMethods.openAppSettings: () {
        opened++;
        return null;
      },
    });
    await pumpSetup(tester);

    await tester.tap(find.text('前往系統設定'));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('前往系統設定 reports why the settings could not be opened', (tester) async {
    native({
      'checkPermissions': () => false,
      'requestPermissions': () => true,
      SettingsMethods.openAppSettings: () => throw PlatformException(code: 'NO_ACTIVITY', message: 'no activity for settings'),
    });
    await pumpSetup(tester);

    await tester.tap(find.text('前往系統設定'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('no activity for settings'), findsOneWidget);
  });

  testWidgets('with every permission granted there is no 前往系統設定', (tester) async {
    native({'checkPermissions': () => true});

    await pumpSetup(tester);

    expect(find.text('前往系統設定'), findsNothing);
  });
}
