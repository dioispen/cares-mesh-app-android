import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class SupplyPledge {
  final String pledgeId;   // UUID v4，管理端追蹤用唯一識別碼
  final String userId;
  final String userName;
  final String itemId;
  final String itemName;
  final String unit;
  final int qty;
  final String status;     // pledged / delivered / cancelled
  final DateTime? pledgedAt;

  SupplyPledge({
    String? pledgeId,
    required this.userId,
    required this.userName,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qty,
    this.status = 'pledged',
    this.pledgedAt,
  }) : pledgeId = pledgeId ?? _uuid.v4();

  factory SupplyPledge.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return SupplyPledge(
      pledgeId: doc.id,
      userId: d['userId'] as String,
      userName: d['userName'] as String,
      itemId: d['itemId'] as String,
      itemName: d['itemName'] as String,
      unit: d['unit'] as String,
      qty: (d['qty'] as num).toInt(),
      status: d['status'] as String? ?? 'pledged',
      pledgedAt: (d['pledgedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'userName': userName,
        'itemId': itemId,
        'itemName': itemName,
        'unit': unit,
        'qty': qty,
        'status': status,
        'pledgedAt': FieldValue.serverTimestamp(),
      };

  SupplyPledge copyWith({int? qty, String? status}) => SupplyPledge(
        pledgeId: pledgeId,
        userId: userId,
        userName: userName,
        itemId: itemId,
        itemName: itemName,
        unit: unit,
        qty: qty ?? this.qty,
        status: status ?? this.status,
        pledgedAt: pledgedAt,
      );
}
