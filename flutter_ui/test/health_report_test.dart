import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/health_report.dart';

HealthReport _report({DateTime? reportTime, String? description, bool sos = false}) => HealthReport(
      reporterId: 'uid-1',
      name: '小明',
      area: '台北市中正區',
      status: '輕傷',
      description: description,
      lat: 25.0478,
      lng: 121.5170,
      reportTime: reportTime ?? DateTime.now(),
      phone: '0912345678',
      bloodType: 'O',
      medicalInfo: '盤尼西林過敏',
      emergencyContactName: '王大明',
      emergencyContactPhone: '0987654321',
      emergencyContactRelation: '父親',
      sos: sos,
    );

void main() {
  group('HealthReport', () {
    test('reportTime 一律以 UTC 寫出，字典序等於時間序', () {
      final earlier = _report(
        reportTime: DateTime.utc(2026, 9, 28, 1, 2, 3),
      ).toDetailJson()['reportTime'] as String;
      final later = _report(
        reportTime: DateTime.utc(2026, 9, 28, 1, 2, 4),
      ).toDetailJson()['reportTime'] as String;

      expect(earlier, endsWith('Z'));
      expect(earlier, '2026-09-28T01:02:03.000Z');
      expect(earlier.compareTo(later), lessThan(0));
    });

    test('本地時間會先換算成 UTC，不同時區的裝置才能比較先後', () {
      final local = DateTime.now();
      final json = _report(reportTime: local).toDetailJson();

      expect(
        DateTime.parse(json['reportTime'] as String).toUtc(),
        local.toUtc(),
      );
    });

    test('round-trip 後時間點不變（回來時是本地時間）', () {
      final original = _report(reportTime: DateTime.utc(2026, 9, 28, 12));
      final restored = HealthReport.fromJson(original.toDetailJson());

      expect(restored.reportTime.isUtc, isFalse);
      expect(restored.reportTime.toUtc(), original.reportTime.toUtc());
      expect(restored.reporterId, original.reporterId);
      expect(restored.status, original.status);
      expect(restored.lat, original.lat);
      expect(restored.lng, original.lng);
    });

    test('沒有傷況細項時 description 是 null，不是空字串', () {
      final json = _report(description: null).toDetailJson();

      expect(json['description'], isNull);
      expect(HealthReport.fromJson(json).description, isNull);
    });

    test('Detail Tier 只帶這些欄位：大家都讀得到，不能混進 Sensitive Tier', () {
      // 與 firestore.rules 的 detailTierKeys() 對應（taskStatus／helperId 由
      // health_screen 視情況另外寫入）。多一個欄位，規則就會擋下整筆回報。
      expect(
        _report().toDetailJson().keys.toSet(),
        {
          'id',
          'reporterId',
          'name',
          'area',
          'status',
          'description',
          'lat',
          'lng',
          'reportTime',
          'sos',
          'survey', // 狀況調查的公開那一半（ADR-0007），鍵由 detailSurveyKeys() 另外鎖住
        },
      );
    });

    test('SOS 是 Detail Tier 上的標記（ADR-0004），round-trip 不變；舊文件沒有這個欄位時當作沒有', () {
      final raised = _report(sos: true).toDetailJson();

      expect(raised['sos'], isTrue);
      expect(_report().toDetailJson()['sos'], isFalse);
      expect(HealthReport.fromJson(raised).sos, isTrue);
      expect(HealthReport.fromJson({...raised}..remove('sos')).sos, isFalse);
    });

    test('Sensitive Tier 帶電話、血型、病史與緊急聯絡人', () {
      expect(
        _report().toSensitiveJson(),
        {
          'reporterId': 'uid-1',
          'phone': '0912345678',
          'bloodType': 'O',
          'medicalInfo': '盤尼西林過敏',
          'emergencyContactName': '王大明',
          'emergencyContactPhone': '0987654321',
          'emergencyContactRelation': '父親',
          'surveySensitive': null, // 這筆回報沒有填狀況調查
        },
      );
    });

    test('兩份文件沒有重疊的個人資料欄位', () {
      final detail = _report().toDetailJson().keys.toSet();
      final sensitive = _report().toSensitiveJson().keys.toSet();

      expect(detail.intersection(sensitive), {'reporterId'});
    });

    test('從兩份文件組回來，Sensitive Tier 讀不到時那些欄位是 null', () {
      final original = _report();
      final detailOnly = HealthReport.fromJson(original.toDetailJson());
      final both = HealthReport.fromJson(
        original.toDetailJson(),
        sensitive: original.toSensitiveJson(),
      );

      expect(detailOnly.area, '台北市中正區');
      expect(detailOnly.phone, isNull);
      expect(detailOnly.medicalInfo, isNull);
      expect(both.phone, '0912345678');
      expect(both.emergencyContactRelation, '父親');
    });
  });
}
