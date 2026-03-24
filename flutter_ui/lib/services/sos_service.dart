class SOSService {

  void sendSOS(String userId, double lat, double lng) {
    print("SOS 發送");

    Map<String, dynamic> sosData = {
      "userId": userId,
      "latitude": lat,
      "longitude": lng,
      "timestamp": DateTime.now().toString()
    };

    print(sosData);

    // 未來可以
    // API 發送
    // BLE 發送
    // P2P Mesh
  }

}