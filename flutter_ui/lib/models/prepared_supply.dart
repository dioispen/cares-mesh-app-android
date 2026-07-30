import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class PreparedSupply {
  final String id;          // UUID v4，管理端追蹤用唯一識別碼
  final String citizenId;
  final String itemName;
  final int quantity;
  final DateTime lastUpdated;

  PreparedSupply({
    String? id,
    required this.citizenId,
    required this.itemName,
    required this.quantity,
    required this.lastUpdated,
  }) : id = id ?? _uuid.v4();
}
