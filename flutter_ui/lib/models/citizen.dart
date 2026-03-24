class Citizen {
  final String id;  //
  final String name;

  final double latitude;
  final double longitude;

   bool needsRescue;

  Citizen({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.needsRescue,
  });
}