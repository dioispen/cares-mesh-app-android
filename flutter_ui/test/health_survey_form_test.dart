import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/health_survey.dart';
import 'package:flutter_ui/widgets/health_survey_form.dart';

void main() {
  /// 每次送出的 (status, survey, raiseSos)。
  late List<(String, HealthSurvey, bool)> submitted;

  Future<void> pumpForm(
    WidgetTester tester,
    HealthSurvey survey, {
    String? initialStatus = '安全',
    bool sosRaised = false,
  }) async {
    submitted = [];
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HealthSurveyForm(
          initialStatus: initialStatus,
          initialSurvey: survey,
          submitting: false,
          sosRaised: sosRaised,
          onSubmit: (status, survey, raiseSos) => submitted.add((status, survey, raiseSos)),
          onOpenSos: () {},
        ),
      ),
    ));
  }

  /// 「其中需要特別照顧的」那一列（同行的人），不是「你本人」那一列。
  FilterChip companionChip(WidgetTester tester, String label) => tester.widget<FilterChip>(find.descendant(
        of: find.byKey(const ValueKey('companion-vulnerable')),
        matching: find.widgetWithText(FilterChip, label),
      ));

  bool enabled(WidgetTester tester, String label) => companionChip(tester, label).onSelected != null;

  bool selected(WidgetTester tester, String label) => companionChip(tester, label).selected;

  // 「同住或同行的人」為 0 時，「其中需要特別照顧的」人沒有對象，選項不該選得到。
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

  testWidgets('「我本人」的選項不受同行人數影響', (tester) async {
    await pumpForm(tester, const HealthSurvey());

    final self = find.descendant(of: find.byKey(const ValueKey('self-vulnerable')), matching: find.byType(FilterChip));
    expect(self, findsNWidgets(HealthSurvey.selfVulnerableOptions.length));
    for (final chip in tester.widgetList<FilterChip>(self)) {
      expect(chip.onSelected, isNotNull);
    }
  });

  group('重傷選到需要立即救援的傷勢', () {
    Future<void> chooseSevere(WidgetTester tester, String injury) async {
      await pumpForm(tester, const HealthSurvey(), initialStatus: null);
      await tester.tap(find.text('重傷'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, injury));
      await tester.pump();
    }

    Future<void> submit(WidgetTester tester) async {
      await tester.tap(find.text('送出健康回報'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('提醒可能需要立即救援，送出時問要不要一併舉起 SOS', (tester) async {
      await chooseSevere(tester, '大量出血');
      expect(find.textContaining('可能需要立即救援'), findsOneWidget);

      await submit(tester);
      expect(find.text('要同時舉起 SOS 嗎？'), findsOneWidget);
      expect(submitted, isEmpty);

      await tester.tap(find.text('舉起 SOS 並送出'));
      await tester.pump(const Duration(milliseconds: 300));
      expect([for (final (s, _, r) in submitted) (s, r)], [('重傷', true)]);
    });

    testWidgets('選「只送回報」就不帶 SOS', (tester) async {
      await chooseSevere(tester, '頭部外傷');
      await submit(tester);

      await tester.tap(find.text('只送回報'));
      await tester.pump(const Duration(milliseconds: 300));
      expect([for (final (s, _, r) in submitted) (s, r)], [('重傷', false)]);
    });

    testWidgets('關掉對話框就不送出，填好的內容還在', (tester) async {
      await chooseSevere(tester, '大量出血');
      await submit(tester);

      await tester.tapAt(const Offset(5, 5)); // 點對話框外面
      await tester.pump(const Duration(milliseconds: 300));
      expect(submitted, isEmpty);
      expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, '大量出血')).selected, isTrue);
    });

    testWidgets('沒有危險傷勢時直接送出，不問', (tester) async {
      await chooseSevere(tester, '四肢骨折');
      expect(find.textContaining('可能需要立即救援'), findsNothing);

      await submit(tester);
      expect(find.text('要同時舉起 SOS 嗎？'), findsNothing);
      expect([for (final (s, _, r) in submitted) (s, r)], [('重傷', false)]);
    });

    testWidgets('已經舉著 SOS 時不再問，這份回報本來就會帶著 SOS', (tester) async {
      await pumpForm(tester, const HealthSurvey(), initialStatus: null, sosRaised: true);
      await tester.tap(find.text('重傷'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, '大量出血'));
      await tester.pump();
      await submit(tester);

      expect(find.text('要同時舉起 SOS 嗎？'), findsNothing);
      expect([for (final (s, _, r) in submitted) (s, r)], [('重傷', false)]);
    });
  });
}
