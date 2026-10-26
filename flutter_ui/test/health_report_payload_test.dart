import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/protocol/ble_packet_decoder.dart';

void main() {
  // 跨端權威向量 —— 與 app/.../protocol/DisasterReportTest.kt 的 vectorBytes 相同。
  // version=2, handle=abcdef012345, status=重傷(2), flags=SOS, geohash="wsqqqm"（geohash-6，ADR-0008），
  // reportTime=1_700_000_000 秒。
  final vector = <int>[
    0x02,
    0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
    0x02,
    0x01, // flags: SOS
    0x06,
    0x77, 0x73, 0x71, 0x71, 0x71, 0x6D, // "wsqqqm"
    0x65, 0x53, 0xF1, 0x00, // 1700000000 秒
  ];

  // 同上但沒有 SOS（DisasterReportTest.kt 的 vectorNoSosBytes）。
  final vectorNoSos = [...vector]..[8] = 0x00;

  // version=2, status=未宣告(3), flags=SOS, 沒有 geohash（vectorUndeclaredSosBytes）。
  final vectorUndeclaredSos = <int>[
    0x02,
    0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
    0x03,
    0x01,
    0x00,
    0x65, 0x53, 0xF1, 0x00,
  ];

  // 版本 1（沒有 flags byte）：status=重傷, geohash="wsqqqm"（vectorV1Bytes）。
  final vectorV1 = <int>[
    0x01,
    0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
    0x02,
    0x06,
    0x77, 0x73, 0x71, 0x71, 0x71, 0x6D,
    0x65, 0x53, 0xF1, 0x00,
  ];

  test('decodes the authoritative Broadcast Tier vector', () {
    final p = HealthReportPayload.decode(vector)!;
    expect(p.reporterHandle, 'abcdef012345');
    expect(p.status, '重傷');
    expect(p.sos, isTrue);
    expect(p.geohash, 'wsqqqm');
    expect(p.reportTime.millisecondsSinceEpoch, 1700000000000);
  });

  test('a zero flags byte means no SOS', () {
    final p = HealthReportPayload.decode(vectorNoSos)!;
    expect(p.status, '重傷');
    expect(p.sos, isFalse);
  });

  test('未宣告 with SOS and no location', () {
    final p = HealthReportPayload.decode(vectorUndeclaredSos)!;
    expect(p.status, '未宣告');
    expect(p.sos, isTrue);
    expect(p.geohash, isNull);
  });

  test('a version 1 report still decodes, as no SOS', () {
    final p = HealthReportPayload.decode(vectorV1)!;
    expect(p.status, '重傷');
    expect(p.sos, isFalse);
    expect(p.geohash, 'wsqqqm');
    expect(p.reportTime.millisecondsSinceEpoch, 1700000000000);
  });

  test('reserved flag bits are ignored, only bit0 is SOS', () {
    expect(HealthReportPayload.decode([...vector]..[8] = 0xFF)!.sos, isTrue);
    expect(HealthReportPayload.decode([...vector]..[8] = 0xFE)!.sos, isFalse);
  });

  test('rejects 未宣告 without SOS and 安全 with SOS (ADR-0004)', () {
    expect(HealthReportPayload.decode([...vectorUndeclaredSos]..[8] = 0x00), isNull);
    expect(HealthReportPayload.decode([...vector]..[7] = 0x00), isNull);
    // 版本 1 沒有 SOS，「未宣告」在版本 1 一律不合法
    expect(HealthReportPayload.decode([...vectorV1]..[7] = 0x03), isNull);
  });

  test('vector is within the Broadcast Tier size bound', () {
    // 1 + 6 + 1 + 1 + 1 + 6 + 4 = 20：geohash-6 讓上界從 19 增為 20（ADR-0008）
    expect(vector.length, 20);
  });

  test('carries no readable identity — handle is opaque hex', () {
    final p = HealthReportPayload.decode(vector)!;
    expect(p.reporterHandle, matches(RegExp(r'^[0-9a-f]{12}$')));
    // 型別上就沒有 name / phone / bloodType / description 欄位
  });

  test('rejects unknown payload version', () {
    expect(HealthReportPayload.decode([...vector]..[0] = 0x09), isNull);
    expect(HealthReportPayload.decode([...vector]..[0] = 0x03), isNull);
    expect(HealthReportPayload.decode([...vector]..[0] = 0x00), isNull);
  });

  test('rejects truncated / junk payload', () {
    expect(HealthReportPayload.decode([0x01, 0x02, 0x03]), isNull);
    expect(HealthReportPayload.decode(const []), isNull);
  });

  test('rejects an illegal geohash length', () {
    expect(HealthReportPayload.decode([...vector]..[9] = 0x03), isNull); // geohashLen 既非 0 也非 6
    expect(HealthReportPayload.decode([...vectorV1]..[8] = 0x03), isNull);
  });

  test('rejects a geohash-5 report from an older device, and any other length (ADR-0008)', () {
    for (final length in const [1, 5, 7, 12]) {
      final geohash = 'wsqqqmwsqqqm'.substring(0, length).codeUnits;
      final v2 = [0x02, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x02, 0x01, length, ...geohash, 0x65, 0x53, 0xF1, 0x00];
      final v1 = [0x01, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x02, length, ...geohash, 0x65, 0x53, 0xF1, 0x00];
      expect(HealthReportPayload.decode(v2), isNull, reason: 'version 2, geohash length $length');
      expect(HealthReportPayload.decode(v1), isNull, reason: 'version 1, geohash length $length');
    }
  });

  test('no-location vector round-trips to a null geohash', () {
    final noLoc = <int>[
      0x02,
      0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
      0x01, // status 輕傷
      0x00, // flags
      0x00, // geohashLen 0
      0x65, 0x53, 0xF1, 0x00,
    ];
    final p = HealthReportPayload.decode(noLoc)!;
    expect(p.geohash, isNull);
    expect(p.approximateLatLng(), isNull);
    expect(p.status, '輕傷');
  });

  test('approximate location is the center of the geohash-6 cell', () {
    final p = HealthReportPayload.decode(vector)!;
    final approx = p.approximateLatLng()!;
    // "wsqqqm" 是台北 101 所在的那一格（約 0.6 × 1.1 km）；與 DisasterReportTest.kt 的
    // approximateCenterOfTheAuthoritativeVector 同一個中心。互助任務的距離與導航用的就是它。
    expect(approx.$1, closeTo(25.03509521484375, 1e-12));
    expect(approx.$2, closeTo(121.5692138671875, 1e-12));
  });

  test('toBroadcastReport drops every Detail Tier field and keeps the SOS', () {
    final r = HealthReportPayload.decode(vector)!.toBroadcastReport();
    expect(r.reporterHandle, 'abcdef012345');
    expect(r.status, '重傷');
    expect(r.sos, isTrue);
    expect(r.approxLat, isNotNull);
    expect(r.approxLng, isNotNull);
  });
}
