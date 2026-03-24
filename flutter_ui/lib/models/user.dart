import 'dart:math';

class AppUser {
  final String id;                       // 系統產生的 User ID
  final String name;                     // 姓名
  final String phone;                    // 手機號碼
  final String area;                     // 居住區域
  final String emergencyContactName;     // 緊急聯絡人姓名
  final String emergencyContactPhone;    // 緊急聯絡人電話
  final String emergencyContactRelation; // 與緊急聯絡人關係
  final String? bloodType;              // 血型（可選）
  final String? medicalInfo;            // 慢性病 / 藥物過敏（可選）
  final DateTime registeredAt;           // 註冊時間

  AppUser({
    required this.id,
    required this.name,
    required this.phone,
    required this.area,
    required this.emergencyContactName,
    required this.emergencyContactPhone,
    required this.emergencyContactRelation,
    this.bloodType,
    this.medicalInfo,
    required this.registeredAt,
  });

  /// 產生唯一 User ID
  static String generateId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = Random().nextInt(99999).toString().padLeft(5, '0');
    return 'UID-$now-$rand';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'area': area,
        'emergencyContactName': emergencyContactName,
        'emergencyContactPhone': emergencyContactPhone,
        'emergencyContactRelation': emergencyContactRelation,
        'bloodType': bloodType,
        'medicalInfo': medicalInfo,
        'registeredAt': registeredAt.toIso8601String(),
      };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        phone: json['phone'] as String,
        area: json['area'] as String,
        emergencyContactName: json['emergencyContactName'] as String,
        emergencyContactPhone: json['emergencyContactPhone'] as String,
        emergencyContactRelation: json['emergencyContactRelation'] as String,
        bloodType: json['bloodType'] as String?,
        medicalInfo: json['medicalInfo'] as String?,
        registeredAt: DateTime.parse(json['registeredAt'] as String),
      );
}
