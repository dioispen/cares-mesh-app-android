class PreparedSupply {
  final String citizenId;
  final String itemName;
  final int quantity;

  final DateTime lastUpdated;

  PreparedSupply({
    required this.citizenId,
    required this.itemName,
    required this.quantity,
    required this.lastUpdated,
  });
}