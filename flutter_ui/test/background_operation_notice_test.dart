import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/background_operation.dart';
import 'package:flutter_ui/models/settings_state.dart';
import 'package:flutter_ui/services/background_operation_service.dart';
import 'package:flutter_ui/widgets/background_operation_notice.dart';

import 'support/screen_sizes.dart';

/// What native answers `getSystemStatus` with, and what the notice asked native to do.
class _Native {
  Map<String, dynamic>? status = _status('backgroundDisabled');
  Object? fixError;
  final calls = <String>[];
  final events = StreamController<Map<String, dynamic>>.broadcast();
  bool listened = false;

  BackgroundOperationService service() => BackgroundOperationService(
        getSystemStatus: () async => status,
        events: () {
          listened = true;
          return events.stream;
        },
        setBackgroundEnabled: (enabled) async => _call('setBackgroundEnabled:$enabled'),
        requestSettingsPermission: (category) async => _call('requestSettingsPermission:$category'),
        requestPermissions: () async => _call('requestPermissions'),
        startMesh: () async => _call('startMesh'),
      );

  void _call(String call) {
    calls.add(call);
    if (fixError != null) throw fixError!;
  }

  void push(Map<String, dynamic> next) {
    status = next;
    events.add(next);
  }
}

Map<String, dynamic> _status(String operation, {String? permission}) => {
      'type': 'system_status',
      'bluetoothEnabled': true,
      'backgroundOperation': operation,
      'backgroundPermission': ?permission,
    };

void main() {
  group('BackgroundOperationStatus', () {
    test('reads the operation and the missing permission from system_status', () {
      expect(
        BackgroundOperationStatus.fromSystemStatus(_status('permissionsMissing', permission: 'nearbyDevices')),
        const BackgroundOperationStatus(
          BackgroundOperation.permissionsMissing,
          missingPermission: SettingsPermissionCategory.nearbyDevices,
        ),
      );
      for (final operation in BackgroundOperation.values) {
        expect(BackgroundOperationStatus.fromSystemStatus(_status(operation.wireName))?.operation, operation);
      }
    });

    test('an older native without the field, or an unknown value, gives no status', () {
      expect(BackgroundOperationStatus.fromSystemStatus({'type': 'system_status', 'bluetoothEnabled': true}), isNull);
      expect(BackgroundOperationStatus.fromSystemStatus(_status('somethingNew')), isNull);
    });

    test('every problem has a notice with a fix, and an active service has none', () {
      expect(backgroundNoticeFor(const BackgroundOperationStatus(BackgroundOperation.active)), isNull);
      expect(backgroundNoticeFor(const BackgroundOperationStatus(BackgroundOperation.backgroundDisabled))?.action,
          BackgroundNoticeAction.enableBackground);
      expect(backgroundNoticeFor(const BackgroundOperationStatus(BackgroundOperation.notRunning))?.action,
          BackgroundNoticeAction.restartService);

      final permission = backgroundNoticeFor(const BackgroundOperationStatus(
        BackgroundOperation.permissionsMissing,
        missingPermission: SettingsPermissionCategory.location,
      ))!;
      expect(permission.action, BackgroundNoticeAction.requestPermission);
      expect(permission.title, '缺少「位置」權限');
      expect(backgroundNoticeFor(const BackgroundOperationStatus(BackgroundOperation.permissionsMissing))!.title,
          '缺少必要權限');
    });
  });

  group('BackgroundOperationNotice', () {
    late _Native native;

    setUp(() {
      native = _Native();
      resetBackgroundNoticeDismissal();
    });

    tearDown(() => native.events.close());

    Future<void> pumpNotice(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: BackgroundOperationNotice(service: native.service()))));
      await tester.pump();
    }

    /// Native pushes [status]: the first pump delivers the event, the second draws the frame it asked for.
    Future<void> deliver(WidgetTester tester, Map<String, dynamic> status) async {
      native.push(status);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('tells the user background operation is off and turns it on', (tester) async {
      await pumpNotice(tester);

      expect(find.text('背景執行已關閉'), findsOneWidget);
      await tester.tap(find.text('開啟背景執行'));
      await tester.pump();
      expect(native.calls, ['setBackgroundEnabled:true']);

      // The service comes up: native pushes the new status and the notice goes away.
      await deliver(tester, _status('active'));
      expect(find.text('背景執行已關閉'), findsNothing);
      await tester.pump(BackgroundOperationNotice.recheckAfter);
    });

    testWidgets('asks for the missing permission by its category', (tester) async {
      native.status = _status('permissionsMissing', permission: 'nearbyDevices');
      await pumpNotice(tester);

      expect(find.text('缺少「附近的裝置」權限'), findsOneWidget);
      await tester.tap(find.text('授權'));
      await tester.pump(BackgroundOperationNotice.recheckAfter);

      expect(native.calls, ['requestSettingsPermission:nearbyDevices']);
    });

    testWidgets('restarts a service that should be running but is not', (tester) async {
      native.status = _status('notRunning');
      await pumpNotice(tester);

      await tester.tap(find.text('重新啟動'));
      await tester.pump(BackgroundOperationNotice.recheckAfter);

      expect(native.calls, ['startMesh']);
    });

    testWidgets('re-reads the status after a fix even without an event', (tester) async {
      await pumpNotice(tester);
      await tester.tap(find.text('開啟背景執行'));
      await tester.pump();

      native.status = _status('active');
      await tester.pump(BackgroundOperationNotice.recheckAfter);
      await tester.pump();

      expect(find.text('背景執行已關閉'), findsNothing);
    });

    testWidgets('a failed fix is reported and the notice stays', (tester) async {
      native.fixError = PlatformException(code: 'NO_ACTIVITY', message: '沒有畫面');
      await pumpNotice(tester);

      await tester.tap(find.text('開啟背景執行'));
      await tester.pump();

      expect(find.text('操作失敗：沒有畫面'), findsOneWidget);
      expect(find.text('背景執行已關閉'), findsOneWidget);
      await tester.pump(BackgroundOperationNotice.recheckAfter);
    });

    testWidgets('a dismissed notice stays away for that reason and comes back for another', (tester) async {
      await pumpNotice(tester);

      await tester.tap(find.byTooltip('關閉提示'));
      await tester.pump();
      expect(find.text('背景執行已關閉'), findsNothing);

      // Coming back to the home page in the same session does not bring it back.
      await tester.pumpWidget(const SizedBox());
      await pumpNotice(tester);
      expect(find.text('背景執行已關閉'), findsNothing);

      await deliver(tester, _status('permissionsMissing', permission: 'nearbyDevices'));
      expect(find.text('缺少「附近的裝置」權限'), findsOneWidget);
    });

    testWidgets('once operation is back to normal, the same problem is shown again', (tester) async {
      await pumpNotice(tester);
      await tester.tap(find.byTooltip('關閉提示'));
      await tester.pump();

      await deliver(tester, _status('active'));
      await deliver(tester, _status('backgroundDisabled'));

      expect(find.text('背景執行已關閉'), findsOneWidget);
    });

    testWidgets('shows nothing and listens to nothing without a native status', (tester) async {
      native.status = null;
      await pumpNotice(tester);

      expect(find.byType(FilledButton), findsNothing);
      expect(native.listened, isFalse);
    });

    for (final screen in layoutCases) {
      testWidgets('the longest notice fits on $screen', (tester) async {
        useScreen(tester, screen);
        native.status = _status('permissionsMissing', permission: 'nearbyDevices');

        await pumpNotice(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('授權'), findsOneWidget);
      });
    }

    testWidgets('shows nothing while background operation is active', (tester) async {
      native.status = _status('active');
      await pumpNotice(tester);

      expect(find.byType(FilledButton), findsNothing);
      expect(native.listened, isTrue);
    });
  });
}
