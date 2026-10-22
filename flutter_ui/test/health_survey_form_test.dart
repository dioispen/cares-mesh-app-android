import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/health_survey.dart';
import 'package:flutter_ui/widgets/health_survey_form.dart';

/// 「同住或同行的人」為 0 時，「其中需要特別照顧的」人沒有對象，選項不該選得到。
void main() {
  Future<void> pumpForm(WidgetTester tester, HealthSurvey survey) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HealthSurveyForm(
          initialStatus: '安全',
          initialSurvey: survey,
          submitting: false,
          onSubmit: (_, _) {},
          onOpenSos: () {},
        ),
      ),
    ));
  }

  bool enabled(WidgetTester tester, String label) =>
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, label)).onSelected != null;

  bool selected(WidgetTester tester, String label) =>
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, label)).selected;

  testWidgets('只有我（0 人）時選不到長者等選項，寵物仍可以選', (tester) async {
    await pumpForm(tester, const HealthSurvey());

    expect(enabled(tester, '長者'), isFalse);
    expect(enabled(tester, '幼童'), isFalse);
    expect(enabled(tester, '寵物'), isTrue);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();

    expect(enabled(tester, '長者'), isTrue);
  });

  testWidgets('人數減回 0 時，已選的人一併取消', (tester) async {
    await pumpForm(tester, const HealthSurvey(companions: 1, vulnerable: ['長者', '寵物']));
    expect(selected(tester, '長者'), isTrue);

    await tester.tap(find.byIcon(Icons.remove_rounded));
    await tester.pump();

    expect(selected(tester, '長者'), isFalse);
    expect(selected(tester, '寵物'), isTrue);
  });
}
