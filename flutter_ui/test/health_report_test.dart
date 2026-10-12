import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/health_report.dart';

HealthReport _report({DateTime? reportTime, String? description}) => HealthReport(
      reporterId: 'uid-1',
      name: '小明',
      phone: '0912345678',
      bloodType: 'O',
      status: '輕傷',
      description: description,
      lat: 25.0478,
      lng: 121.5170,
      reportTime: reportTime ?? DateTime.now(),
    );

void main() {
  group('HealthReport', () {
    test('reportTime 一律以 UTC 寫出，字典序等於時間序', () {
      final earlier = _report(
        reportTime: DateTime.utc(2026, 9, 28, 1, 2, 3),
      ).toJson()['reportTime'] as String;
      final later = _report(
        reportTime: DateTime.utc(2026, 9, 28, 1, 2, 4),
      ).toJson()['reportTime'] as String;

      expect(earlier, endsWith('Z'));
      expect(earlier, '2026-09-28T01:02:03.000Z');
      expect(earlier.compareTo(later), lessThan(0));
    });

    test('本地時間會先換算成 UTC，不同時區的裝置才能比較先後', () {
      final local = DateTime.now();
      final json = _report(reportTime: local).toJson();

      expect(
        DateTime.parse(json['reportTime'] as String).toUtc(),
        local.toUtc(),
      );
    });

    test('round-trip 後時間點不變（回來時是本地時間）', () {
      final original = _report(reportTime: DateTime.utc(2026, 9, 28, 12));
      final restored = HealthReport.fromJson(original.toJson());

      expect(restored.reportTime.isUtc, isFalse);
      expect(restored.reportTime.toUtc(), original.reportTime.toUtc());
      expect(restored.reporterId, original.reporterId);
      expect(restored.status, original.status);
      expect(restored.lat, original.lat);
      expect(restored.lng, original.lng);
    });

    test('沒有傷況細項時 description 是 null，不是空字串', () {
      final json = _report(description: null).toJson();

      expect(json['description'], isNull);
      expect(HealthReport.fromJson(json).description, isNull);
    });

    test('toJson 只帶這些欄位：taskStatus／helperId 不由回報端寫入', () {
      // taskStatus／helperId 是協助者那側才會寫的欄位。回報端用不帶 merge 的 set()
      // 覆寫整份文件，所以它們不在這裡就等於「改狀態會回到等待中／無人認領」。
      expect(
        _report().toJson().keys.toSet(),
        {
          'id',
          'reporterId',
          'name',
          'phone',
          'bloodType',
          'status',
          'description',
          'lat',
          'lng',
          'reportTime',
        },
      );
    });
  });
}
