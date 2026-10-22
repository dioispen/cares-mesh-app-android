import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart';

/// `BitchatBridge.sendHealthReport` tells its caller when the Health Report did not go out over
/// the mesh, instead of pretending it did.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> send({bool sos = false}) => BitchatBridge.sendHealthReport(
        reporterHandle: 'abcdef012345',
        status: '重傷',
        lat: 23.97,
        lng: 120.97,
        sos: sos,
      );

  Future<List<MethodCall>> recordCalls(Future<void> Function() action) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    await action();
    return calls;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('hands the Broadcast Tier to the native side and completes once it took it', () async {
    final calls = await recordCalls(send);

    expect(calls.single.method, 'sendHealthReport');
    expect(calls.single.arguments, {
      'reporterHandle': 'abcdef012345',
      'status': '重傷',
      'lat': 23.97,
      'lng': 120.97,
      'sos': false,
    });
  });

  test('carries the SOS mark', () async {
    final calls = await recordCalls(() => send(sos: true));

    expect((calls.single.arguments as Map)['sos'], isTrue);
  });

  test('sends exactly the fields the native side reads', () async {
    // flutter test 的工作目錄是 flutter_ui/，../app 是同一份 checkout 的 Kotlin 端。
    final kotlin = File('../app/src/main/java/com/bitchat/android/flutter/HealthReportBridgeMap.kt')
        .readAsStringSync();
    final nativeKeys = {for (final m in RegExp(r'map\["(\w+)"\]').allMatches(kotlin)) m.group(1)!};

    final calls = await recordCalls(send);

    expect((calls.single.arguments as Map).keys.toSet(), nativeKeys);
  });

  test('a native error is passed on, with its code', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: HealthReportErrors.serviceNotReady, message: 'Mesh service is not running');
    });

    await expectLater(
      send(),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', HealthReportErrors.serviceNotReady)),
    );
  });

  test('without a native mesh the caller learns nothing was broadcast', () async {
    await expectLater(send(), throwsA(isA<MissingPluginException>()));
  });
}
