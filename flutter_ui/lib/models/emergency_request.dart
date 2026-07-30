import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class EmergencyRequest {
  final String id;          // UUID v4，管理端追蹤用唯一識別碼
  final String citizenId;
  final double latitude;
  final double longitude;
  final String type;
  // sos / medical / supply
  final String? description;
  final List<String>? neededSupplies;
  // 可為 null 純求救
  final DateTime createdAt;

  EmergencyRequest({
    String? id,
    required this.citizenId,
    required this.latitude,
    required this.longitude,
    required this.type,
    this.description,
    this.neededSupplies,
    required this.createdAt,
  }) : id = id ?? _uuid.v4();
}
