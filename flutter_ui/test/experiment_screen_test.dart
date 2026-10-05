import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart' show ExperimentErrors, ExperimentMethods;
import 'package:flutter_ui/screens/experiment_screen.dart';

/// The debug-only field-experiment screen (#70 §3) against a fake native experiment bridge on the
/// real method channel, so the exact wire calls are what is checked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The phone's wall clock as the screen reads it.
  late DateTime now;

  /// Every call the screen made to native, in order.
  late List<MethodCall> calls;

  /// What native answers `experiment_getStatus` with (or throws, when an exception).
  late Object status;

  /// What native answers `experiment_startSender` / `experiment_stopSender` with (or throws).
  late Object startReply;
  late Object stopReply;

  Map<String, Object?> sender({
    String state = 'idle',
    int sent = 0,
    int failed = 0,
    int written = 0,
    int noLink = 0,
    int total = 0,
    DateTime? startsAt,
    String? handle,
    int? ttl,
    int? intervalMs,
  }) =>
      {
        'state': state,
        'sent': sent,
        'failed': failed,
        'written': written,
        'noLink': noLink,
        'total': total,
        'startsAtMs': startsAt?.millisecondsSinceEpoch,
        'handle': handle,
        'ttl': ttl,
        'intervalMs': intervalMs,
      };

  Map<String, Object?> statusMap({
    int links = 2,
    String powerMode = 'BALANCED',
    bool? systemPowerSave = false,
    String? peerId = 'a1b2c3d4',
    Map<String, int> rx20s = const {},
    Map<String, int> rx60s = const {},
    Map<String, Object?>? senderStatus,
  }) =>
      {
        'links': links,
        'powerMode': powerMode,
        'systemPowerSave': systemPowerSave,
        'peerId': peerId,
        'rx20s': rx20s,
        'rx60s': rx60s,
        'sender': senderStatus ?? sender(),
      };

  Iterable<MethodCall> callsOf(String method) => calls.where((call) => call.method == method);

  setUp(() {
    now = DateTime(2026, 10, 4, 14, 0, 0);
    calls = [];
    status = statusMap();
    startReply = sender(state: 'sending', total: 50, startsAt: now, handle: 'ee0000000001', ttl: 3, intervalMs: 1000);
    stopReply = sender(state: 'stopped', sent: 3, total: 50, startsAt: now, handle: 'ee0000000001', ttl: 3, intervalMs: 1000);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final reply = switch (call.method) {
        ExperimentMethods.getStatus => status,
        ExperimentMethods.startSender => startReply,
        ExperimentMethods.stopSender => stopReply,
        _ => throw MissingPluginException(call.method),
      };
      if (reply is Exception) throw reply;
      return reply;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Lets the bridge replies arrive and the screen rebuild.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    // Tall enough that the whole screen is laid out and tappable without scrolling.
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ExperimentScreen(clock: () => now)));
    await settle(tester);
  }

  String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  Future<void> selectDevice(WidgetTester tester, int device) async {
    await tester.tap(find.byKey(const ValueKey('experiment-device')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('$device（ee000000000$device）').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapStart(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('experiment-start')));
    await settle(tester);
  }

  group('live panel', () {
    testWidgets('shows links, power mode, peer id and the RX counts of every handle', (tester) async {
      status = statusMap(
        links: 3,
        powerMode: 'POWER_SAVER',
        peerId: 'a1b2c3d4',
        rx20s: {'ee0000000002': 5},
        rx60s: {'ee0000000002': 12, 'ee0000000003': 1},
      );

      await pumpScreen(tester);

      expect(textOf(tester, 'experiment-links'), '3');
      expect(textOf(tester, 'experiment-power-mode'), 'POWER_SAVER（省電）');
      expect(textOf(tester, 'experiment-peer-id'), 'a1b2c3d4');
      for (var device = 1; device <= 10; device++) {
        expect(find.text('ee${device.toString().padLeft(10, '0')}'), findsOneWidget, reason: 'device $device listed');
      }
      expect(textOf(tester, 'experiment-rx20-ee0000000002'), '5');
      expect(textOf(tester, 'experiment-rx60-ee0000000002'), '12');
      expect(textOf(tester, 'experiment-rx20-ee0000000003'), '0');
      expect(textOf(tester, 'experiment-rx60-ee0000000003'), '1');
      expect(textOf(tester, 'experiment-rx60-ee0000000010'), '0');
      expect(textOf(tester, 'experiment-system-power-save'), '關');
    });

    testWidgets('a phone with the system battery saver on is flagged, whatever the app mode says', (tester) async {
      status = statusMap(powerMode: 'BALANCED', systemPowerSave: true);

      await pumpScreen(tester);

      expect(textOf(tester, 'experiment-power-mode'), 'BALANCED（平衡）');
      expect(textOf(tester, 'experiment-system-power-save'), '開（會影響實驗）');
    });

    testWidgets('an unknown battery saver state is shown as unknown', (tester) async {
      status = statusMap(systemPowerSave: null);

      await pumpScreen(tester);

      expect(textOf(tester, 'experiment-system-power-save'), '—');
    });

    testWidgets('follows native, polling about once a second', (tester) async {
      await pumpScreen(tester);
      expect(callsOf(ExperimentMethods.getStatus), hasLength(1));

      status = statusMap(links: 4, rx20s: {'ee0000000001': 2}, rx60s: {'ee0000000001': 2});
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      expect(callsOf(ExperimentMethods.getStatus), hasLength(2));
      expect(textOf(tester, 'experiment-links'), '4');
      expect(textOf(tester, 'experiment-rx20-ee0000000001'), '2');
    });

    testWidgets('stops polling once the screen is closed', (tester) async {
      await pumpScreen(tester);
      await tester.pumpWidget(const SizedBox());
      final polls = callsOf(ExperimentMethods.getStatus).length;

      await tester.pump(const Duration(seconds: 5));

      expect(callsOf(ExperimentMethods.getStatus).length, polls);
    });

    testWidgets('a phone whose mesh is not running says so instead of showing a peer id', (tester) async {
      status = statusMap(peerId: null, links: 0);

      await pumpScreen(tester);

      expect(textOf(tester, 'experiment-peer-id'), 'mesh 未啟動');
      expect(textOf(tester, 'experiment-links'), '0');
    });

    testWidgets('a failed poll is shown and the last numbers stay until the next one works', (tester) async {
      await pumpScreen(tester);

      status = PlatformException(code: 'BOOM');
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      expect(textOf(tester, 'experiment-poll-error'), '讀取狀態失敗：原生錯誤（BOOM）');
      expect(textOf(tester, 'experiment-links'), '2');

      status = statusMap(links: 5);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      expect(find.byKey(const ValueKey('experiment-poll-error')), findsNothing);
      expect(textOf(tester, 'experiment-links'), '5');
    });

    testWidgets('shows how far the sender got', (tester) async {
      status = statusMap(
        senderStatus: sender(
            state: 'sending', sent: 12, failed: 1, written: 9, noLink: 2, total: 50, startsAt: now, handle: 'ee0000000003', ttl: 7, intervalMs: 200),
      );

      await pumpScreen(tester);

      expect(textOf(tester, 'experiment-sender-state'), '發送中');
      expect(textOf(tester, 'experiment-sender-progress'), '12 / 50');
      expect(textOf(tester, 'experiment-sender-outcome'), '有鏈路 9・無鏈路 2・mesh 未收下 1');
      expect(textOf(tester, 'experiment-sender-job'), 'ee0000000003・TTL 7・間隔 200 ms');
    });
  });

  group('sender', () {
    testWidgets('開始 hands the form to native as the exact argument map', (tester) async {
      await pumpScreen(tester);

      await selectDevice(tester, 3);
      await tester.enterText(find.byKey(const ValueKey('experiment-count')), '20');
      await tester.enterText(find.byKey(const ValueKey('experiment-interval')), '200');
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('experiment-ttl')), matching: find.text('7')));
      await tester.enterText(find.byKey(const ValueKey('experiment-start-at')), '9:05:00');
      await tester.tap(find.text('重傷'));
      await tester.pump();
      await tapStart(tester);

      expect(callsOf(ExperimentMethods.startSender).single.arguments, {
        'device': 3,
        'count': 20,
        'intervalMs': 200,
        'ttl': 7,
        'startAt': '09:05:00',
        'status': '重傷',
      });
    });

    testWidgets('the defaults start now with TTL 3 and Status 安全; a 0 ms burst is allowed', (tester) async {
      await pumpScreen(tester);

      await selectDevice(tester, 1);
      await tester.enterText(find.byKey(const ValueKey('experiment-interval')), '0');
      await tapStart(tester);

      expect(callsOf(ExperimentMethods.startSender).single.arguments, {
        'device': 1,
        'count': 50,
        'intervalMs': 0,
        'ttl': 3,
        'startAt': null,
        'status': '安全',
      });
    });

    testWidgets('the form shows the handle the chosen device sends with', (tester) async {
      await pumpScreen(tester);

      await selectDevice(tester, 5);

      expect(textOf(tester, 'experiment-device-handle'), 'handle：ee0000000005');
    });

    testWidgets('shows the native reply at once, with the scheduled start counting down', (tester) async {
      await pumpScreen(tester);
      startReply = sender(state: 'waiting', total: 50, startsAt: DateTime(2026, 10, 4, 14, 1, 30), handle: 'ee0000000002', ttl: 3, intervalMs: 1000);

      await selectDevice(tester, 2);
      await tester.enterText(find.byKey(const ValueKey('experiment-start-at')), '14:01:30');
      await tapStart(tester);

      expect(textOf(tester, 'experiment-sender-state'), '等待開始');
      expect(textOf(tester, 'experiment-sender-start'), '今天 14:01:30');
      expect(textOf(tester, 'experiment-sender-countdown'), '倒數 0:01:30');

      status = statusMap(senderStatus: startReply as Map<String, Object?>);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      expect(textOf(tester, 'experiment-sender-countdown'), '倒數 0:01:29');
    });

    testWidgets('a start time that already passed today is visibly tomorrow', (tester) async {
      status = statusMap(
        senderStatus: sender(state: 'waiting', total: 50, startsAt: DateTime(2026, 10, 5, 13, 0, 0), handle: 'ee0000000001', ttl: 3, intervalMs: 1000),
      );

      await pumpScreen(tester);

      expect(textOf(tester, 'experiment-sender-start'), '明天 13:00:00');
      expect(textOf(tester, 'experiment-sender-countdown'), '倒數 23:00:00');
    });

    testWidgets('no countdown once the sender is no longer waiting', (tester) async {
      status = statusMap(
        senderStatus: sender(state: 'stopped', total: 50, startsAt: DateTime(2026, 10, 4, 15, 0, 0), handle: 'ee0000000001', ttl: 3, intervalMs: 1000),
      );

      await pumpScreen(tester);

      expect(textOf(tester, 'experiment-sender-start'), '今天 15:00:00');
      expect(find.byKey(const ValueKey('experiment-sender-countdown')), findsNothing);
    });

    group('invalid input never reaches native', () {
      testWidgets('no device chosen', (tester) async {
        await pumpScreen(tester);

        await tapStart(tester);

        expect(callsOf(ExperimentMethods.startSender), isEmpty);
        expect(find.text('請選擇裝置編號'), findsOneWidget);
      });

      testWidgets('a count below 1', (tester) async {
        await pumpScreen(tester);
        await selectDevice(tester, 1);

        await tester.enterText(find.byKey(const ValueKey('experiment-count')), '0');
        await tapStart(tester);

        expect(callsOf(ExperimentMethods.startSender), isEmpty);
        expect(find.text('筆數要是 1 以上的整數'), findsOneWidget);
      });

      testWidgets('no interval', (tester) async {
        await pumpScreen(tester);
        await selectDevice(tester, 1);

        await tester.enterText(find.byKey(const ValueKey('experiment-interval')), '');
        await tapStart(tester);

        expect(callsOf(ExperimentMethods.startSender), isEmpty);
        expect(find.text('間隔要是 0 以上的整數（ms）'), findsOneWidget);
      });

      testWidgets('a start time that is not HH:mm:ss', (tester) async {
        await pumpScreen(tester);
        await selectDevice(tester, 1);

        await tester.enterText(find.byKey(const ValueKey('experiment-start-at')), '25:00:00');
        await tapStart(tester);

        expect(callsOf(ExperimentMethods.startSender), isEmpty);
        expect(find.text('請輸入 HH:mm:ss（24 小時制），或留空立即開始'), findsOneWidget);
      });
    });

    testWidgets('a running sender cannot be started again', (tester) async {
      status = statusMap(senderStatus: sender(state: 'sending', sent: 1, total: 50, startsAt: now, handle: 'ee0000000001', ttl: 3, intervalMs: 1000));

      await pumpScreen(tester);

      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('experiment-start'))).onPressed, isNull);
    });

    testWidgets('停止 asks native to stop and shows the result', (tester) async {
      status = statusMap(senderStatus: sender(state: 'sending', sent: 3, total: 50, startsAt: now, handle: 'ee0000000001', ttl: 3, intervalMs: 1000));
      await pumpScreen(tester);

      await tester.tap(find.byKey(const ValueKey('experiment-stop')));
      await settle(tester);

      expect(callsOf(ExperimentMethods.stopSender), hasLength(1));
      expect(textOf(tester, 'experiment-sender-state'), '已停止');
    });

    for (final (code, reason) in [
      (ExperimentErrors.serviceNotReady, 'mesh 服務未啟動'),
      (ExperimentErrors.alreadyRunning, '發送器已在執行，請先停止'),
      (ExperimentErrors.invalidArgument, '參數不合法'),
    ]) {
      testWidgets('a native $code refusal to start is explained', (tester) async {
        startReply = PlatformException(code: code);
        await pumpScreen(tester);
        await selectDevice(tester, 1);

        await tapStart(tester);

        expect(find.text('無法開始：$reason'), findsOneWidget);
        expect(textOf(tester, 'experiment-sender-state'), '閒置');
      });
    }

    testWidgets('a native refusal to stop is explained', (tester) async {
      stopReply = PlatformException(code: ExperimentErrors.serviceNotReady);
      await pumpScreen(tester);

      await tester.tap(find.byKey(const ValueKey('experiment-stop')));
      await settle(tester);

      expect(find.text('無法停止：mesh 服務未啟動'), findsOneWidget);
    });
  });
}
