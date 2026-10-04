import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart' show ExperimentMethods;
import 'package:flutter_ui/screens/experiment_screen.dart';
import 'package:flutter_ui/screens/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The hidden entry to the debug-only experiment screen (#70 §3). Tests run as a debug build
/// (`kDebugMode` is true); that release builds have no entry is checked at source level in
/// `bridge_contract_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitchat/bridge/methods');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == ExperimentMethods.getStatus) return <String, Object?>{'links': 0, 'sender': {'state': 'idle'}};
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
  }

  testWidgets('long-pressing the header shield opens the experiment screen', (tester) async {
    await pumpHome(tester);

    await tester.longPress(find.byIcon(Icons.shield_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ExperimentScreen), findsOneWidget);
  });

  testWidgets('a plain tap on the shield does nothing', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.byIcon(Icons.shield_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ExperimentScreen), findsNothing);
  });
}
