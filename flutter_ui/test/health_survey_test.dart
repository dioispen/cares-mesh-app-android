import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/health_report.dart';
import 'package:flutter_ui/models/health_survey.dart';

void main() {
  const survey = HealthSurvey(
    injuries: ['割傷', '扭傷'],
    mobility: '需要協助才能移動',
    location: '家中',
    companions: 2,
    vulnerable: ['長者'],
    housing: '輕微損壞，仍可居住',
    needs: ['飲用水', '藥品'],
    notes: '  家中長者的降血壓藥快用完了  ',
  );

  test('injurySummary 沿用 description 的寫法；沒有傷勢時為 null', () {
    expect(survey.injurySummary, '割傷、扭傷');
    expect(const HealthSurvey().injurySummary, isNull);
  });

  test('改成「安全」時清掉傷勢，其餘調查內容保留', () {
    final safe = survey.forStatus('安全');
    expect(safe.injuries, isEmpty);
    expect(safe.needs, ['飲用水', '藥品']);
    expect(survey.forStatus('輕傷').injuries, ['割傷', '扭傷']);
  });

  test('★ 敏感項目只出現在 Sensitive Tier（ADR-0007）', () {
    expect(survey.toDetailMap().keys,
        unorderedEquals(['mobility', 'location', 'companions', 'housing', 'needs']));
    expect(survey.toSensitiveMap().keys, unorderedEquals(['vulnerable', 'notes']));
    expect(survey.toDetailMap().values.toString(), isNot(contains('長者')));
    expect(survey.toDetailMap().values.toString(), isNot(contains('降血壓藥')));
  });

  test('兩半合回來不失真；傷勢由 description 拆回，只留認得的選項', () {
    final restored = HealthSurvey.fromMaps(
      description: '割傷、扭傷、不是選項',
      detail: survey.toDetailMap(),
      sensitive: survey.toSensitiveMap(),
    );
    expect(restored.injuries, ['割傷', '扭傷']);
    expect(restored.mobility, survey.mobility);
    expect(restored.companions, 2);
    expect(restored.vulnerable, ['長者']);
    expect(restored.notes, '家中長者的降血壓藥快用完了');
  });

  test('withSensitive 只換掉敏感的那一半', () {
    final s = HealthSurvey.fromMaps(detail: survey.toDetailMap())
        .withSensitive({'vulnerable': ['幼童'], 'notes': '需要奶粉'});
    expect(s.needs, ['飲用水', '藥品']);
    expect(s.vulnerable, ['幼童']);
    expect(s.notes, '需要奶粉');
  });

  test('欄位缺漏或型別錯誤的舊文件退回預設值，不會丟例外', () {
    final s = HealthSurvey.fromMaps(
      detail: {'companions': '2', 'needs': ['飲用水', 3, null]},
      sensitive: {'vulnerable': '長者', 'notes': null},
    );
    expect(s.companions, 0);
    expect(s.needs, ['飲用水']);
    expect(s.vulnerable, isEmpty);
    expect(s.notes, '');
    expect(HealthSurvey.fromMaps().needs, isEmpty);
  });

  test('HealthReport 把 survey 拆進兩份文件，讀回來也拿得到', () {
    final report = HealthReport(
      reporterId: 'uid-alice',
      name: 'Alice',
      status: '輕傷',
      description: survey.injurySummary,
      reportTime: DateTime.utc(2026, 10, 22, 8),
      phone: '0912345678',
      survey: survey,
    );
    final detail = report.toDetailJson();
    final sensitive = report.toSensitiveJson();
    expect((detail['survey'] as Map).keys, isNot(contains('notes')));
    expect((sensitive['surveySensitive'] as Map)['vulnerable'], ['長者']);

    final restored = HealthReport.fromJson(detail, sensitive: sensitive).survey!;
    expect(restored.needs, ['飲用水', '藥品']);
    expect(restored.vulnerable, ['長者']);
    expect(restored.injuries, ['割傷', '扭傷']);
  });

  test('沒有填調查時 survey 寫成 null（merge 寫入才會清掉上一次的調查）', () {
    final report = HealthReport(
      reporterId: 'uid-alice',
      name: 'Alice',
      status: '安全',
      reportTime: DateTime.utc(2026, 10, 22, 8),
    );
    expect(report.toDetailJson().containsKey('survey'), isTrue);
    expect(report.toDetailJson()['survey'], isNull);
    expect(HealthReport.fromJson(report.toDetailJson()).survey, isNull);
  });
}
