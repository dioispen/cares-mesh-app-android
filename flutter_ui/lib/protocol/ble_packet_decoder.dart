import 'dart:typed_data';

import '../models/health_report.dart';
import 'geohash.dart';

/// BLE 封包類型常數，與 Android MessageType 對應
class BlePacketType {
  static const int announce      = 0x01;
  static const int message       = 0x02;
  static const int leave         = 0x03;
  static const int noiseHandshake = 0x10;
  static const int noiseEncrypted = 0x11;
  static const int fragment      = 0x20;
  static const int requestSync   = 0x21;
  static const int fileTransfer  = 0x22;
  static const int healthReport  = 0x30;
}

/// 通用 BLE 封包包裝器（Android Bridge 傳來的統一格式）
class BlePacket {
  final int packetType;
  final String senderId;
  final int timestamp;
  final List<int> payload;

  const BlePacket({
    required this.packetType,
    required this.senderId,
    required this.timestamp,
    required this.payload,
  });

  factory BlePacket.fromEvent(Map<String, dynamic> event) {
    return BlePacket(
      packetType: (event['packetType'] as num).toInt(),
      senderId: event['senderId'] as String? ?? '',
      timestamp: (event['timestamp'] as num?)?.toInt() ?? 0,
      payload: List<int>.from(event['payload'] as List? ?? []),
    );
  }
}

/// Broadcast Tier（A1，見 ADR-0003）—— Health Report 中每台裝置都能讀的部分。
///
/// **不含任何 PII**：沒有真實姓名、電話、血型、自由文字，也沒有公尺級座標。
/// 對應 `app/.../protocol/DisasterReportPacket.kt` 的 `HealthReportPayload` 線路格式（big-endian）：
/// ```
///   [0]     version(1) = 2        也接受 1（沒有 flags，視為沒有 SOS）；其他版本一律拒收
///   [1..6]  reporterHandle(6)     不具識別性的固定長度識別碼
///   [7]     status(1)             0=安全 / 1=輕傷 / 2=重傷 / 3=未宣告
///   [8]     flags(1)              bit0 = SOS；其餘位元忽略（版本 1 沒有這個 byte）
///   [9]     geohashLen(1)         0 或 geohashPrecision
///   [10..]  geohash(ASCII)        降精度近似位置
///   [末 4]  reportTime(4)         Unix 秒，uint32 big-endian
/// ```
///
/// SOS 是 Health Report 上的標記（ADR-0004）：「未宣告」只能和 SOS 一起出現，「安全」不能帶
/// SOS，不合法的組合一律拒收。
class HealthReportPayload {
  static const int version = 2;
  static const int _versionWithoutFlags = 1;
  static const int handleBytes = 6;
  static const int geohashPrecision = 5;
  static const int _flagSos = 0x01;

  /// 最短的合法 payload：版本 1、沒有 geohash。
  static const int _minEncodedSize = 1 + handleBytes + 1 + 1 + 4;

  /// 12 個十六進位字元（6 bytes）。
  final String reporterHandle;

  /// '安全' / '輕傷' / '重傷' / '未宣告'。線路上是單一 byte，這裡還原成中文 label 供 UI 使用。
  final String status;

  /// Reporter 是否正舉著 SOS。
  final bool sos;

  /// 降精度 geohash；無位置資訊時為 null。
  final String? geohash;

  /// 回報時間（線路上只保留到秒）。
  final DateTime reportTime;

  const HealthReportPayload({
    required this.reporterHandle,
    required this.status,
    this.sos = false,
    this.geohash,
    required this.reportTime,
  });

  /// status wire byte ↔ 中文 label 的單一對應（與 Kotlin `HealthStatus` 一致）。
  static const Map<int, String> statusByWire = {0: '安全', 1: '輕傷', 2: '重傷', 3: statusUndeclared};

  static HealthReportPayload? decode(List<int> bytes) {
    try {
      if (bytes.length < _minEncodedSize) return null;
      final b = Uint8List.fromList(bytes);
      var o = 0;

      final v = b[o++] & 0xFF;
      if (v != version && v != _versionWithoutFlags) return null;

      final handle = [
        for (var i = 0; i < handleBytes; i++)
          (b[o + i] & 0xFF).toRadixString(16).padLeft(2, '0'),
      ].join();
      o += handleBytes;

      final status = statusByWire[b[o++] & 0xFF];
      if (status == null) return null;
      final sos = v == version && (b[o++] & _flagSos) != 0;
      if (!_isLegal(status, sos: sos)) return null;

      final ghLen = b[o++] & 0xFF;
      if (ghLen != 0 && ghLen != geohashPrecision) return null;
      if (bytes.length - o < ghLen + 4) return null;
      final geohash =
          ghLen == 0 ? null : String.fromCharCodes(b.sublist(o, o + ghLen));
      o += ghLen;

      final secs = ByteData.sublistView(b, o, o + 4).getUint32(0, Endian.big);

      return HealthReportPayload(
        reporterHandle: handle,
        status: status,
        sos: sos,
        geohash: geohash,
        reportTime:
            DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true),
      );
    } catch (_) {
      return null;
    }
  }

  /// 「未宣告」只能和 SOS 一起出現；「安全」不能帶 SOS（與 Kotlin `HealthReportPayload.isLegal` 一致）。
  static bool _isLegal(String status, {required bool sos}) => switch (status) {
        statusUndeclared => sos,
        '安全' => !sos,
        _ => true,
      };

  /// geohash 還原的近似中心座標；無位置時為 null。這是「大約在哪」而非確切位置。
  (double, double)? approximateLatLng() =>
      geohash == null ? null : Geohash.decodeCenter(geohash!);

  BroadcastHealthReport toBroadcastReport() {
    final approx = approximateLatLng();
    return BroadcastHealthReport(
      reporterHandle: reporterHandle,
      status: status,
      sos: sos,
      geohash: geohash,
      approxLat: approx?.$1,
      approxLng: approx?.$2,
      reportTime: reportTime,
    );
  }
}
