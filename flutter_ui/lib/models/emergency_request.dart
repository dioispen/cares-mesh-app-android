class EmergencyRequest {
  final String id;
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
    required this.id,
    required this.citizenId,
    required this.latitude,
    required this.longitude,
    required this.type,
    this.description,
    this.neededSupplies,
    required this.createdAt,
  });
}