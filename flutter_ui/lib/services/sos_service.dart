import 'package:cloud_firestore/cloud_firestore.dart';

class SOSService {
  Future<String> sendSOS({
    required String userId,
    required String userName,
    required String phone,
    required double lat,
    required double lng,
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
