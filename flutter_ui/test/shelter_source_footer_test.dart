import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/shelter_screen.dart';

import 'support/screen_sizes.dart';

/// 防災地圖本身是 WebView，測試裡無法建立，所以只測地圖下方的資料來源列（#79）。
void main() {
  late List<String> opened;

  setUp(() => opened = []);

  Future<void> pumpFooter(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              ShelterSourceFooter(onOpen: opened.add),
            ],
          ),
        ),
      ));

  for (final screen in layoutCases) {
    testWidgets('the source line fits on $screen', (tester) async {
      useScreen(tester, screen);

      await pumpFooter(tester);

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('on a narrow phone with large text the second source wraps onto its own line', (tester) async {
    useScreen(tester, smallPhoneLargeText);

    await pumpFooter(tester);

    final footer = tester.getRect(find.byType(ShelterSourceFooter));
    final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(ShelterSourceFooter), matching: find.byType(RichText)).first);
    final text = paragraph.text.toPlainText();
    double lineOf(String part) =>
        paragraph.getOffsetForCaret(TextPosition(offset: text.indexOf(part)), Rect.zero).dy;
    expect(footer.right, lessThanOrEqualTo(smallPhoneLargeText.size.width));
    expect(lineOf('內政部警政署（NPA）'), greaterThan(lineOf('kiang.github.io/air_raid_shelter')));
  });

  testWidgets('both sources stay tappable', (tester) async {
    useScreen(tester, smallPhoneLargeText);
    await pumpFooter(tester);

    await tester.tapOnText(find.textRange.ofSubstring('kiang.github.io/air_raid_shelter'));
    await tester.tapOnText(find.textRange.ofSubstring('內政部警政署（NPA）'));

    expect(opened, ['https://kiang.github.io/air_raid_shelter/', 'https://adr.npa.gov.tw/']);
  });
}
