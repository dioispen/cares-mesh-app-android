import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class Citizen {
  final String id;         // UUID v4，管理端追蹤用唯一識別碼
  final String name;
  final double latitude;
  final double longitude;
  bool needsRescue;

  Citizen({
    String? id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.needsRescue,
  }) : id = id ?? _uuid.v4();
}
