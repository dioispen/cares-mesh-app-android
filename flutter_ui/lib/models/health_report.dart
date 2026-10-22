import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Status「未宣告」：Reporter 舉起 SOS 時沒有說明自己的狀況。只會和 SOS 一起出現（ADR-0004）。
const statusUndeclared = '未宣告';

/// 本機自填的完整 Health Report。上傳到後端時拆成兩份文件（ADR-0005）：
///
/// * [toDetailJson] → `health_reports/{uid}`：Detail Tier（姓名、居住區域、Status 與傷勢
///   細項、精確座標、回報時間），任何登入帳號都讀得到。
/// * [toSensitiveJson] → `health_report_sensitive/{uid}`：Sensitive Tier（電話、血型、
///   病史、緊急聯絡人），只有本人與正接著這筆任務的 Verified Rescuer 讀得到。
///
/// 兩者都**不會**原樣進入 BLE 廣播；廣播出去的是 [BroadcastHealthReport] 對應的
/// Broadcast Tier（見 ADR-0003）。
class HealthReport {
  final String id;          // UUID v4，管理端追蹤用唯一識別碼
  final String reporterId;  // 回報者 ID

  // ── Detail Tier ──
  final String name;        // 回報者姓名
  final String? area;       // 居住區域
  final String status;      // 健康狀態：'安全' / '輕傷' / '重傷' / '未宣告'（只和 SOS 一起出現）
  final String? description; // 傷勢細項（選項，不是自由輸入；可選）
  final double? lat;         // 緯度（可選）
  final double? lng;         // 經度（可選）
  final DateTime reportTime; // 回報時間
  final bool sos;            // Reporter 正舉著 SOS（ADR-0004）

  // ── Sensitive Tier ──
  final String? phone;                    // 聯絡電話
  final String? bloodType;                // 血型（可選）
  final String? medicalInfo;              // 慢性病 / 藥物過敏（可選）
  final String? emergencyContactName;     // 緊急聯絡人姓名
  final String? emergencyContactPhone;    // 緊急聯絡人電話
  final String? emergencyContactRelation; // 與緊急聯絡人關係

  HealthReport({
    String? id,
    required this.reporterId,
    required this.name,
    this.area,
    required this.status,
    this.description,
    this.lat,
    this.lng,
    required this.reportTime,
    this.sos = false,
    this.phone,
    this.bloodType,
    this.medicalInfo,
    this.emergencyContactName,
    this.emergencyContactPhone,
    this.emergencyContactRelation,
  }) : id = id ?? _uuid.v4();

  /// `health_reports/{uid}` 的內容。欄位必須與 firestore.rules 的 detailTierKeys() 一致，
  /// 規則會擋下任何多出來的欄位——這份文件大家都讀得到。
  Map<String, dynamic> toDetailJson() => {
        'id': id,
        'reporterId': reporterId,
        'name': name,
        'area': area,
        'status': status,
        'description': description,
        'lat': lat,
        'lng': lng,
        // 一律存 UTC（結尾帶 Z）。存本地時間的字串沒有時區資訊，不同時區的裝置
        // 混在同一個 collection 裡就無法比較先後，字典序也不再等於時間序。
        'reportTime': reportTime.toUtc().toIso8601String(),
        'sos': sos,
      };

  /// `health_report_sensitive/{uid}` 的內容。
  Map<String, dynamic> toSensitiveJson() => {
        'reporterId': reporterId,
        'phone': phone,
        'bloodType': bloodType,
        'medicalInfo': medicalInfo,
        'emergencyContactName': emergencyContactName,
        'emergencyContactPhone': emergencyContactPhone,
        'emergencyContactRelation': emergencyContactRelation,
      };

  /// 從 `health_reports/{uid}`（[detail]）組回一份回報；讀得到 Sensitive Tier 時一併傳入
  /// [sensitive]。
  factory HealthReport.fromJson(
    Map<String, dynamic> detail, {
    Map<String, dynamic>? sensitive,
  }) =>
      HealthReport(
        id: detail['id'] as String?,
        reporterId: detail['reporterId'] as String,
        name: detail['name'] as String,
        area: detail['area'] as String?,
        status: detail['status'] as String,
        description: detail['description'] as String?,
        lat: (detail['lat'] as num?)?.toDouble(),
        lng: (detail['lng'] as num?)?.toDouble(),
        // 舊文件是沒有時區的本地時間字串，parse 後當成本地時間；帶 Z 的新文件
        // 會解析成 UTC，這裡統一轉回本地時間再交給 UI。
        reportTime: DateTime.parse(detail['reportTime'] as String).toLocal(),
        // #83 之前的文件沒有 sos 欄位。
        sos: detail['sos'] == true,
        phone: sensitive?['phone'] as String?,
        bloodType: sensitive?['bloodType'] as String?,
        medicalInfo: sensitive?['medicalInfo'] as String?,
        emergencyContactName: sensitive?['emergencyContactName'] as String?,
        emergencyContactPhone: sensitive?['emergencyContactPhone'] as String?,
        emergencyContactRelation: sensitive?['emergencyContactRelation'] as String?,
      );
}

/// 從 BLE 廣播收到的 Health Report —— 只有 Broadcast Tier。
///
/// 與本機自填的 [HealthReport] 是**不同來源**：這裡永遠沒有真實姓名、電話、血型、
/// 傷勢細項或精確座標。UI 不得假設收到的回報帶有這些欄位。
class BroadcastHealthReport {
  /// 不具識別性的固定長度識別碼，不可反推回帳號或 Firestore 文件。
  final String reporterHandle;

  /// '安全' / '輕傷' / '重傷' / '未宣告'。
  final String status;

  /// Reporter 是否正舉著 SOS。
  final bool sos;

  /// 降精度 geohash；無位置時為 null。
  final String? geohash;

  /// 由 [geohash] 還原的近似座標；無位置時為 null。
  final double? approxLat;
  final double? approxLng;

  final DateTime reportTime;

  const BroadcastHealthReport({
    required this.reporterHandle,
    required this.status,
    this.sos = false,
    this.geohash,
    this.approxLat,
    this.approxLng,
    required this.reportTime,
  });
}
