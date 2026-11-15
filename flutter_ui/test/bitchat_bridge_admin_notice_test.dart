import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart';

/// The Admin Notice recipient key methods (#140) as Kotlin `AdminNoticeBridge` reads them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == AdminNoticeMethods.getPublicKey ? key : null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('getAdminNoticePublicKey asks for the key bound to the uid and returns its bytes', () async {
    expect(await BitchatBridge.getAdminNoticePublicKey('uid-alice'), key);

    expect(calls.single.method, 'adminNotice_getPublicKey');
    expect(calls.single.arguments, {'uid': 'uid-alice'});
  });

  test('clearAdminNoticeKey asks native to delete the key', () async {
    await BitchatBridge.clearAdminNoticeKey();

    expect(calls.single.method, 'adminNotice_clearKey');
  });

  test('a native error is passed on with its code', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: AdminNoticeErrors.keyStoreUnavailable),
    );

    await expectLater(
      BitchatBridge.clearAdminNoticeKey(),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'KEY_STORE_UNAVAILABLE')),
    );
  });
}
