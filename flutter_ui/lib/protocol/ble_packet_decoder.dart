import 'dart:typed_data';

import '../models/health_report.dart';

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
  static const int supplyExchange = 0x32;
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

/// 精確座標在線路上的解析度：1 度 = 10^7 個單位（約 1.1 cm）。與 Kotlin `ReportLocation.SCALE` 相同。
const int coordinateScale = 10000000;

/// 把座標換成線路上的整數：四捨五入，0.5 往正無限大，與 Kotlin `ReportLocation.of`（`roundToLong`）
/// 同一規則。互助任務以它把後端的 `lat`／`lng` 換算成與 mesh 相同的單位來比對（ADR-0010）。
int coordinateToE7(double degrees) => (degrees * coordinateScale + 0.5).floor();

/// Broadcast Tier（見 ADR-0003、ADR-0008）—— Health Report 中每台裝置都能讀的部分。
///
/// **不含姓名與聯絡方式**：沒有真實姓名、電話、血型、自由文字。位置是精確座標，與 Detail Tier
/// 是同一份。對應 `app/.../protocol/DisasterReportPacket.kt` 的 `HealthReportPayload` 線路格式
/// （big-endian）：
/// ```
///   [0]      version(1) = 3       其他版本（含 geohash 的 1、2）一律拒收
///   [1..6]   reporterHandle(6)    隨機的固定長度識別碼
///   [7]      status(1)            0=安全 / 1=輕傷 / 2=重傷 / 3=未宣告
///   [8]      flags(1)             bit0 = SOS，bit1 = 有位置；其餘位元忽略
///   [9..16]  lat, lng(2 × 4)      int32 big-endian，單位 1e-7 度；只在 bit1 = 1 時出現
///   [末 4]   reportTime(4)        Unix 秒，uint32 big-endian
/// ```
///
/// SOS 是 Health Report 上的標記（ADR-0004）：「未宣告」只能和 SOS 一起出現，「安全」不能帶
/// SOS，不合法的組合一律拒收。
class HealthReportPayload {
  static const int version = 3;
  static const int handleBytes = 6;
  static const int _flagSos = 0x01;
  static const int _flagLocation = 0x02;
  static const int _locationBytes = 8;
  static const int _maxLatE7 = 90 * coordinateScale;
  static const int _maxLngE7 = 180 * coordinateScale;

  /// 沒有位置的 payload：1 + handle + status + flags + time。
  static const int _minEncodedSize = 1 + handleBytes + 1 + 1 + 4;

  /// 帶位置的 payload，也是 Broadcast Tier 的上界（與 Kotlin `MAX_ENCODED_SIZE` 相同）。
  static const int maxEncodedSize = _minEncodedSize + _locationBytes;

  /// 12 個十六進位字元（6 bytes）。
  final String reporterHandle;

  /// '安全' / '輕傷' / '重傷' / '未宣告'。線路上是單一 byte，這裡還原成中文 label 供 UI 使用。
  final String status;

  /// Reporter 是否正舉著 SOS。
  final bool sos;

  /// 精確座標，線路上的整數（單位 1e-7 度）；無位置資訊時兩者都是 null。
  final int? latE7;
  final int? lngE7;

  /// 回報時間（線路上只保留到秒）。
  final DateTime reportTime;

  const HealthReportPayload({
    required this.reporterHandle,
    required this.status,
    this.sos = false,
    this.latE7,
    this.lngE7,
    required this.reportTime,
  });

  double? get lat => latE7 == null ? null : latE7! / coordinateScale;
  double? get lng => lngE7 == null ? null : lngE7! / coordinateScale;

  /// status wire byte ↔ 中文 label 的單一對應（與 Kotlin `HealthStatus` 一致）。
  static const Map<int, String> statusByWire = {0: '安全', 1: '輕傷', 2: '重傷', 3: statusUndeclared};

  static HealthReportPayload? decode(List<int> bytes) {
    try {
      if (bytes.length < _minEncodedSize) return null;
      final b = Uint8List.fromList(bytes);
      var o = 0;

      final v = b[o++] & 0xFF;
      if (v != version) return null;

      final handle = [
        for (var i = 0; i < handleBytes; i++)
          (b[o + i] & 0xFF).toRadixString(16).padLeft(2, '0'),
      ].join();
      o += handleBytes;

      final status = statusByWire[b[o++] & 0xFF];
      if (status == null) return null;
      final flags = b[o++] & 0xFF;
      final sos = (flags & _flagSos) != 0;
      if (!_isLegal(status, sos: sos)) return null;

      final hasLocation = (flags & _flagLocation) != 0;
      if (bytes.length != _minEncodedSize + (hasLocation ? _locationBytes : 0)) return null;
      final view = ByteData.sublistView(b);
      int? latE7;
      int? lngE7;
      if (hasLocation) {
        latE7 = view.getInt32(o, Endian.big);
        lngE7 = view.getInt32(o + 4, Endian.big);
        o += _locationBytes;
        if (latE7.abs() > _maxLatE7 || lngE7.abs() > _maxLngE7) return null;
      }

      final secs = view.getUint32(o, Endian.big);

      return HealthReportPayload(
        reporterHandle: handle,
        status: status,
        sos: sos,
        latE7: latE7,
        lngE7: lngE7,
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

  BroadcastHealthReport toBroadcastReport() => BroadcastHealthReport(
        reporterHandle: reporterHandle,
        status: status,
        sos: sos,
        lat: lat,
        lng: lng,
        reportTime: reportTime,
      );
}
