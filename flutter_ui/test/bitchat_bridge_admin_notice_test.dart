import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart';

/// The Admin Notice methods as Kotlin `AdminNoticeBridge` reads them: the recipient key (#140) and
/// the notice list (#142).
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

  test('getAdminNotices returns the list native answers, as it is', () async {
    final notices = [
      {'messageId': 'a1b2c3d4e5f60718', 'read': false},
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return notices;
    });

    expect(await BitchatBridge.getAdminNotices(), notices);
    expect(calls.single.method, 'adminNotice_getAll');
  });

  test('getAdminNotices answered with null is an error, not an empty list', () async {
    await expectLater(BitchatBridge.getAdminNotices(), throwsA(isA<PlatformException>()));
  });

  test('markAdminNoticeRead names the notice', () async {
    await BitchatBridge.markAdminNoticeRead('a1b2c3d4e5f60718');

    expect(calls.single.method, 'adminNotice_markRead');
    expect(calls.single.arguments, {'messageId': 'a1b2c3d4e5f60718'});
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
