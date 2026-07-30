import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class AdminSupply {
  final String id;          // UUID v4，管理端追蹤用唯一識別碼
  final String itemName;    // 物資名稱
  int totalQuantity;        // 總量
  int allocatedQuantity;    // 已分配量

  AdminSupply({
    String? id,
    required this.itemName,
    required this.totalQuantity,
    this.allocatedQuantity = 0,
  }) : id = id ?? _uuid.v4();

  int get remainingQuantity => totalQuantity - allocatedQuantity;

  void allocate(int quantity) {
    if (quantity <= remainingQuantity) {
      allocatedQuantity += quantity;
    } else {
      throw Exception('庫存不足');
    }
  }
}
