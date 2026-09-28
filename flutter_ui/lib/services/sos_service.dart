import 'package:cloud_firestore/cloud_firestore.dart';

class SOSService {
  /// 送出一筆 SOS。
  ///
  /// [lat]／[lng] 可以是 null —— 拿不到定位時寫入 null，而不是 0.0。
  /// 0, 0 是幾內亞灣外海的真實座標，救援端會把它當成一個可信的位置。
  Future<String> sendSOS({
    required String userId,
    required String userName,
    required String phone,
    required double? lat,
    required double? lng,
    String? bloodType,
    String? medicalInfo,
  }) async {
    final doc = await FirebaseFirestore.instance.collection('sos_requests').add({
      'userId': userId,
      'userName': userName,
      'phone': phone,
      'latitude': lat,
      'longitude': lng,
      'bloodType': bloodType,
      'medicalInfo': medicalInfo,
      'status': 'active',
      'sentAt': FieldValue.serverTimestamp(),
    });
    return doc.id;
  }
}
