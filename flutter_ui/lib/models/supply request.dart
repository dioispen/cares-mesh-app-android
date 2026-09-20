import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class SupplyRequest {
  final String requestId;  // UUID v4，管理端追蹤用唯一識別碼
  final String userId;
  final String userName;
  final String itemId;
  final String itemName;
  final String unit;
  final int qty;
  final String status;     // pending / fulfilled / cancelled
  final DateTime? createdAt;

  SupplyRequest({
    String? requestId,
    required this.userId,
    required this.userName,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qty,
    this.status = 'pending',
    this.createdAt,
  }) : requestId = requestId ?? _uuid.v4();

  factory SupplyRequest.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return SupplyRequest(
      requestId: doc.id,
      userId: d['userId'] as String,
      userName: d['userName'] as String,
      itemId: d['itemId'] as String,
      itemName: d['itemName'] as String,
      unit: d['unit'] as String,
      qty: (d['quantity'] as num).toInt(),
      status: d['status'] as String? ?? 'pending',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'userName': userName,
        'itemId': itemId,
        'itemName': itemName,
        'unit': unit,
        'quantity': qty,
        'status': status,
        'createdAt': FieldValue.serverTimestamp(),
      };
}
