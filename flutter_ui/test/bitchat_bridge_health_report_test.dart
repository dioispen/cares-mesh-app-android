import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart';

/// `BitchatBridge.sendHealthReport` tells its caller when the Health Report did not go out over
/// the mesh, instead of pretending it did.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const broadcastTier = {'reporterHandle': 'abcdef012345', 'status': '重傷', 'lat': 23.97, 'lng': 120.97};

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('hands the Broadcast Tier to the native side and completes once it took it', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    await BitchatBridge.sendHealthReport(broadcastTier);

    expect(calls.single.method, 'sendHealthReport');
    expect(calls.single.arguments, broadcastTier);
  });

  test('a native error is passed on, with its code', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: HealthReportErrors.serviceNotReady, message: 'Mesh service is not running');
    });

    await expectLater(
      BitchatBridge.sendHealthReport(broadcastTier),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', HealthReportErrors.serviceNotReady)),
    );
  });

  test('without a native mesh the caller learns nothing was broadcast', () async {
    await expectLater(BitchatBridge.sendHealthReport(broadcastTier), throwsA(isA<MissingPluginException>()));
  });
}
