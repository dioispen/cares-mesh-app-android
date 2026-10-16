import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart';

/// The setup-flow bridge methods (#71): only a missing native implementation degrades to a
/// fallback value; an error the native side reports is passed on to the caller with its code.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void answer(String method, Object? Function() reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, method);
      return reply();
    });
  }

  final cases = <({String method, Future<Object?> Function() call, Object? success, Object? fallback, String code})>[
    (
      method: 'getSystemStatus',
      call: BitchatBridge.getSystemStatus,
      success: {'bluetoothEnabled': true},
      fallback: null,
      code: 'STATUS_FAILED',
    ),
    (method: 'checkPermissions', call: BitchatBridge.checkPermissions, success: true, fallback: false, code: 'CHECK_FAILED'),
    (method: 'requestPermissions', call: BitchatBridge.requestPermissions, success: true, fallback: false, code: 'NO_ACTIVITY'),
    (method: 'isRegistered', call: BitchatBridge.isRegistered, success: true, fallback: false, code: 'IDENTITY_UNAVAILABLE'),
    (method: 'startMesh', call: BitchatBridge.startMesh, success: true, fallback: false, code: 'START_FAILED'),
  ];

  for (final c in cases) {
    group(c.method, () {
      test('returns what the native side answers', () async {
        answer(c.method, () => c.success);

        expect(await c.call(), c.success);
      });

      test('without a native implementation it degrades to ${c.fallback}', () async {
        // No mock handler: the engine answers MissingPluginException, as on iOS or in tests.
        expect(await c.call(), c.fallback);
      });

      test('a native error is passed on with its code and reason', () async {
        answer(c.method, () => throw PlatformException(code: c.code, message: 'native reason'));

        await expectLater(
          c.call(),
          throwsA(isA<PlatformException>()
              .having((e) => e.code, 'code', c.code)
              .having((e) => e.message, 'message', 'native reason')),
        );
      });
    });
  }

  test('getSystemStatus hands back a String-keyed map', () async {
    answer('getSystemStatus', () => <Object?, Object?>{'bluetoothEnabled': false});

    final status = await BitchatBridge.getSystemStatus();

    expect(status, isA<Map<String, dynamic>>());
    expect(status, {'bluetoothEnabled': false});
  });
}
