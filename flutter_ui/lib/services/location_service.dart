class LocationService {

  double latitude = 0;
  double longitude = 0;

  void updateLocation(double lat, double lng) {
    latitude = lat;
    longitude = lng;
  }

  Map<String, double> getLocation() {
    return {
      "lat": latitude,
      "lng": longitude
    };
  }

}