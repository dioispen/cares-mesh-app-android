import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_ui/main.dart';

void main() {
  testWidgets('BitchatFlutterUiApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const BitchatFlutterUiApp());
  });
}
