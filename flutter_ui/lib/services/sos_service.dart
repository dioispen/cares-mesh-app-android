import 'package:cloud_firestore/cloud_firestore.dart';

/// 一筆已交給 Firestore 的 SOS。
///
/// [id] 立刻可用，離線也一樣；[write] 要等伺服器確認才完成，離線時會一直等到
/// 恢復連線（資料已在本機佇列裡）。
typedef SosSubmission = ({String id, Future<void> write});

class SOSService {
  CollectionReference<Map<String, dynamic>> get _sosRequests =>
      FirebaseFirestore.instance.collection('sos_requests');

  /// 送出一筆 SOS。
  ///
  /// [lat]／[lng] 可以是 null —— 拿不到定位時寫入 null，而不是 0.0。
  /// 0, 0 是幾內亞灣外海的真實座標，救援端會把它當成一個可信的位置。
  ///
  /// 先在本機產生文件 reference 再 set()，而不是 add()：add() 要等伺服器確認才
  /// 回傳 ID，離線時根本拿不到，之後定位晚到也就沒辦法把座標補進同一筆 SOS。
  SosSubmission sendSOS({
    required String userId,
    required String userName,
    required String phone,
    required double? lat,
    required double? lng,
    String? bloodType,
    String? medicalInfo,
  }) {
    final ref = _sosRequests.doc();
    final write = ref.set({
      'userId': userId,
      'userName': userName,
      'phone': phone,
      'latitude': lat,
      'longitude': lng,
      'bloodType': bloodType,
      'medicalInfo': medicalInfo,
      'status': 'active',
      // 手機按下 SOS 的時間。離線排隊的 SOS 可能過很久才到伺服器，
      // serverTimestamp() 填的是到達時間，會讓救援端以為是剛剛才求救。
      'requestedAt': Timestamp.now(),
      // 伺服器收到的時間。
      'sentAt': FieldValue.serverTimestamp(),
    });
    return (id: ref.id, write: write);
  }

  /// 把晚到的定位補寫進已送出的 SOS。
  ///
  /// 對救援的人來說，晚一點的位置比沒有位置有用得多。firestore.rules 允許
  /// 本人更新自己的 sos_requests。
  Future<void> attachLocation(String id, {required double lat, required double lng}) {
    return _sosRequests.doc(id).update({
      'latitude': lat,
      'longitude': lng,
      'locationAttachedAt': Timestamp.now(),
    });
  }
}
