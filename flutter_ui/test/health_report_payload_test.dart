import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/protocol/ble_packet_decoder.dart';

void main() {
  // 跨端權威向量 —— 與 app/.../protocol/DisasterReportTest.kt 的 vectorBytes 相同。
  // version=1, handle=abcdef012345, status=重傷(2), geohash="wsqqm", reportTime=1_700_000_000 秒。
  final vector = <int>[
    0x01,
    0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
    0x02,
    0x05,
    0x77, 0x73, 0x71, 0x71, 0x6D, // "wsqqm"
    0x65, 0x53, 0xF1, 0x00, // 1700000000 秒
  ];

  test('decodes the authoritative Broadcast Tier vector', () {
    final p = HealthReportPayload.decode(vector)!;
    expect(p.reporterHandle, 'abcdef012345');
    expect(p.status, '重傷');
    expect(p.geohash, 'wsqqm');
    expect(p.reportTime.millisecondsSinceEpoch, 1700000000000);
  });

  test('vector is within the Broadcast Tier size bound', () {
    // 1 + 6 + 1 + 1 + 5 + 4 = 18
    expect(vector.length, lessThanOrEqualTo(18));
  });

  test('carries no readable identity — handle is opaque hex', () {
    final p = HealthReportPayload.decode(vector)!;
    expect(p.reporterHandle, matches(RegExp(r'^[0-9a-f]{12}$')));
    // 型別上就沒有 name / phone / bloodType / description 欄位
  });

  test('rejects unknown payload version', () {
    final bad = [...vector]..[0] = 0x09;
    expect(HealthReportPayload.decode(bad), isNull);
  });

  test('rejects truncated / junk payload', () {
    expect(HealthReportPayload.decode([0x01, 0x02, 0x03]), isNull);
    expect(HealthReportPayload.decode(const []), isNull);
  });

  test('rejects an illegal geohash length', () {
    final bad = [...vector]..[8] = 0x03; // geohashLen 既非 0 也非 5
    expect(HealthReportPayload.decode(bad), isNull);
  });

  test('no-location vector round-trips to a null geohash', () {
    final noLoc = <int>[
      0x01,
      0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
      0x01, // status 輕傷
      0x00, // geohashLen 0
      0x65, 0x53, 0xF1, 0x00,
    ];
    final p = HealthReportPayload.decode(noLoc)!;
    expect(p.geohash, isNull);
    expect(p.approximateLatLng(), isNull);
    expect(p.status, '輕傷');
  });

  test('approximate location is coarse, not a precise fix', () {
    final p = HealthReportPayload.decode(vector)!;
    final approx = p.approximateLatLng()!;
    // "wsqqm" 落在台北一帶；只斷言量級（geohash-5 ≈ 數公里），不綁死精確值
    expect(approx.$1, inInclusiveRange(24.0, 26.0));
    expect(approx.$2, inInclusiveRange(120.0, 123.0));
  });

  test('toBroadcastReport drops every Detail Tier field', () {
    final r = HealthReportPayload.decode(vector)!.toBroadcastReport();
    expect(r.reporterHandle, 'abcdef012345');
    expect(r.status, '重傷');
    expect(r.approxLat, isNotNull);
    expect(r.approxLng, isNotNull);
  });
}
