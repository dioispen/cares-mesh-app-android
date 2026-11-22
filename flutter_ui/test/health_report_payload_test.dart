import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/protocol/ble_packet_decoder.dart';

void main() {
  // 跨端權威向量 —— 與 app/.../protocol/DisasterReportTest.kt 的 vectorBytes 相同。
  // version=3, handle=abcdef012345, status=重傷(2), flags=SOS|有位置,
  // lat=25.0330000（250330000）, lng=121.5654000（1215654000）, reportTime=1_700_000_000 秒。
  final vector = <int>[
    0x03,
    0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
    0x02,
    0x03, // flags: SOS | 有位置
    0x0E, 0xEB, 0xBB, 0x90, // 250330000
    0x48, 0x75, 0x68, 0x70, // 1215654000
    0x65, 0x53, 0xF1, 0x00, // 1700000000 秒
  ];

  // 同上但沒有 SOS（DisasterReportTest.kt 的 vectorNoSosBytes）。
  final vectorNoSos = [...vector]..[8] = 0x02;

  // version=3, status=未宣告(3), flags=SOS, 沒有位置（vectorUndeclaredSosBytes）。
  final vectorUndeclaredSos = <int>[
    0x03,
    0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
    0x03,
    0x01,
    0x65, 0x53, 0xF1, 0x00,
  ];

  // 負的經緯度：status=輕傷, lat=-33.8688, lng=-151.2093（vectorNegativeBytes）。
  final vectorNegative = <int>[
    0x03,
    0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45,
    0x01,
    0x02,
    0xEB, 0xD0, 0x08, 0x00,
    0xA5, 0xDF, 0x4A, 0xB8,
    0x65, 0x53, 0xF1, 0x00,
  ];

  test('decodes the authoritative Broadcast Tier vector', () {
    final p = HealthReportPayload.decode(vector)!;
    expect(p.reporterHandle, 'abcdef012345');
    expect(p.status, '重傷');
    expect(p.sos, isTrue);
    expect((p.latE7, p.lngE7), (250330000, 1215654000));
    expect((p.lat, p.lng), (25.0330, 121.5654));
    expect(p.reportTime.millisecondsSinceEpoch, 1700000000000);
  });

  test('negative coordinates keep their sign', () {
    final p = HealthReportPayload.decode(vectorNegative)!;
    expect(p.status, '輕傷');
    expect((p.latE7, p.lngE7), (-338688000, -1512093000));
    expect((p.lat, p.lng), (-33.8688, -151.2093));
  });

  test('without SOS only the location flag is set', () {
    final p = HealthReportPayload.decode(vectorNoSos)!;
    expect(p.status, '重傷');
    expect(p.sos, isFalse);
    expect(p.latE7, 250330000);
  });

  test('未宣告 with SOS and no location', () {
    final p = HealthReportPayload.decode(vectorUndeclaredSos)!;
    expect(p.status, '未宣告');
    expect(p.sos, isTrue);
    expect((p.latE7, p.lngE7, p.lat, p.lng), (null, null, null, null));
  });

  test('reserved flag bits are ignored, only bit0 and bit1 count', () {
    expect(HealthReportPayload.decode([...vector]..[8] = 0xFF)!.sos, isTrue);
    expect(HealthReportPayload.decode([...vector]..[8] = 0xFE)!.sos, isFalse);
    expect(HealthReportPayload.decode([...vectorUndeclaredSos]..[8] = 0xFD)!.latE7, isNull);
  });

  test('rejects 未宣告 without SOS and 安全 with SOS (ADR-0004)', () {
    expect(HealthReportPayload.decode([...vectorUndeclaredSos]..[8] = 0x00), isNull);
    expect(HealthReportPayload.decode([...vector]..[7] = 0x00), isNull);
  });

  test('vector is within the Broadcast Tier size bound', () {
    // 1 + 6 + 1 + 1 + 8 + 4 = 21；沒有位置時 13（ADR-0008）
    expect(HealthReportPayload.maxEncodedSize, 21);
    expect(vector.length, 21);
    expect(vectorUndeclaredSos.length, 13);
  });

  test('carries no name or contact details — handle is opaque hex', () {
    final p = HealthReportPayload.decode(vector)!;
    expect(p.reporterHandle, matches(RegExp(r'^[0-9a-f]{12}$')));
    // 型別上就沒有 name / phone / bloodType / description 欄位
  });

  test('rejects unknown payload versions, including the geohash ones (ADR-0008)', () {
    for (final version in const [0x00, 0x01, 0x02, 0x04, 0xFF]) {
      expect(HealthReportPayload.decode([...vector]..[0] = version), isNull, reason: 'version $version');
    }
  });

  test('rejects a geohash report from an older device', () {
    const handle = [0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45];
    const time = [0x65, 0x53, 0xF1, 0x00];
    final geohash = 'wsqqqm'.codeUnits;
    expect(HealthReportPayload.decode([0x02, ...handle, 0x02, 0x01, 0x06, ...geohash, ...time]), isNull);
    expect(HealthReportPayload.decode([0x02, ...handle, 0x03, 0x01, 0x00, ...time]), isNull);
    expect(HealthReportPayload.decode([0x01, ...handle, 0x02, 0x06, ...geohash, ...time]), isNull);
  });

  test('rejects a length that disagrees with the flags', () {
    expect(HealthReportPayload.decode([...vectorUndeclaredSos]..[8] = 0x03), isNull);
    expect(HealthReportPayload.decode([...vector]..[8] = 0x01), isNull);
    expect(HealthReportPayload.decode([...vector, 0x00]), isNull);
    expect(HealthReportPayload.decode([...vectorUndeclaredSos, 0x00]), isNull);
    expect(HealthReportPayload.decode(vector.sublist(0, vector.length - 1)), isNull);
  });

  test('rejects coordinates outside the globe', () {
    // 900000001 = 0x35A4E901；-1800000001 = 0x94B62DFF
    expect(HealthReportPayload.decode([...vector]..setRange(9, 13, [0x35, 0xA4, 0xE9, 0x01])), isNull);
    expect(HealthReportPayload.decode([...vector]..setRange(13, 17, [0x94, 0xB6, 0x2D, 0xFF])), isNull);
  });

  test('rejects truncated / junk payload', () {
    expect(HealthReportPayload.decode([0x03, 0x02, 0x03]), isNull);
    expect(HealthReportPayload.decode(const []), isNull);
  });

  test('coordinateToE7 rounds like the native side, ties toward positive infinity', () {
    expect(coordinateToE7(25.03300004), 250330000);
    expect(coordinateToE7(25.03300006), 250330001);
    expect(coordinateToE7(-25.03300004), -250330000);
    expect(coordinateToE7(-25.03300006), -250330001);
    // 解碼出來的座標換回去就是線路上的整數
    final p = HealthReportPayload.decode(vector)!;
    expect((coordinateToE7(p.lat!), coordinateToE7(p.lng!)), (p.latE7, p.lngE7));
  });

  test('toBroadcastReport drops every Detail Tier field and keeps the SOS and the precise location', () {
    final r = HealthReportPayload.decode(vector)!.toBroadcastReport();
    expect(r.reporterHandle, 'abcdef012345');
    expect(r.status, '重傷');
    expect(r.sos, isTrue);
    expect((r.lat, r.lng), (25.0330, 121.5654));
  });
}
