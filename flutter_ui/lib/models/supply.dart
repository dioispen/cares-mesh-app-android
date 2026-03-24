class AdminSupply {
  final String itemName;  //物資名稱
  int totalQuantity;      // 總量
  int allocatedQuantity;  // 已分配量

  AdminSupply({
    required this.itemName,
    required this.totalQuantity,
    this.allocatedQuantity = 0,
  });

  int get remainingQuantity => totalQuantity - allocatedQuantity;

  void allocate(int quantity) {
    if (quantity <= remainingQuantity) {
      allocatedQuantity += quantity;
    } else {
      throw Exception('庫存不足');
    }
  }
}