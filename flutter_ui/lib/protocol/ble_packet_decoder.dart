import 'dart:convert';
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

/// 健康報告 payload 解碼器
/// 對應 Android HealthReportPayload.encode() 的二進位格式：
///   [reporterIdLen:1B][reporterId:UTF8]
///   [nameLen:1B][name:UTF8]
///   [phoneLen:1B][phone:UTF8]
///   [bloodTypeLen:1B][bloodType:UTF8 或 0 bytes]
///   [statusLen:1B][status:UTF8]
///   [descLen:2B big-endian][description:UTF8 或 0 bytes]
///   [lat:8B double big-endian][lng:8B double big-endian]
///   [reportTimeLen:1B][reportTime:UTF8]
class HealthReportPayload {
  final String reporterId;
  final String name;
  final String phone;
  final String? bloodType;
  final String status;
  final String? description;
  final double? lat;
  final double? lng;
  final String reportTime;

  const HealthReportPayload({
    required this.reporterId,
    required this.name,
    required this.phone,
    this.bloodType,
    required this.status,
    this.description,
    this.lat,
    this.lng,
    required this.reportTime,
  });

  static HealthReportPayload? decode(List<int> bytes) {
    try {
      int offset = 0;

      List<int> take(int len) {
        final slice = bytes.sublist(offset, offset + len);
        offset += len;
        return slice;
      }

      String readUtf8Fixed() {
        final len = bytes[offset] & 0xFF;
        offset++;
        if (len == 0) return '';
        return utf8.decode(take(len));
      }

      String? readNullable1() {
        final len = bytes[offset] & 0xFF;
        offset++;
        if (len == 0) return null;
        return utf8.decode(take(len));
      }

      String? readNullable2() {
        final hi = bytes[offset] & 0xFF;
        final lo = bytes[offset + 1] & 0xFF;
        final len = (hi << 8) | lo;
        offset += 2;
        if (len == 0) return null;
        return utf8.decode(take(len));
      }

      double readFloat64BE() {
        final bd = ByteData(8);
        for (int i = 0; i < 8; i++) {
          bd.setUint8(i, bytes[offset + i] & 0xFF);
        }
        offset += 8;
        return bd.getFloat64(0, Endian.big);
      }

      final reporterId  = readUtf8Fixed();
      final name        = readUtf8Fixed();
      final phone       = readUtf8Fixed();
      final bloodType   = readNullable1();
      final status      = readUtf8Fixed();
      final description = readNullable2();
      final latRaw      = readFloat64BE();
      final lngRaw      = readFloat64BE();
      final lat         = latRaw == 0.0 ? null : latRaw;
      final lng         = lngRaw == 0.0 ? null : lngRaw;
      final reportTime  = readUtf8Fixed();

      if (reporterId.isEmpty || name.isEmpty || status.isEmpty) return null;

      return HealthReportPayload(
        reporterId:  reporterId,
        name:        name,
        phone:       phone,
        bloodType:   bloodType,
        status:      status,
        description: description,
        lat:         lat,
        lng:         lng,
        reportTime:  reportTime,
      );
    } catch (_) {
      return null;
    }
  }

  HealthReport toHealthReport() {
    return HealthReport(
      reporterId:  reporterId,
      name:        name,
      phone:       phone,
      bloodType:   bloodType,
      status:      status,
      description: description,
      lat:         lat,
      lng:         lng,
      reportTime:  DateTime.tryParse(reportTime) ?? DateTime.now(),
    );
  }
}
