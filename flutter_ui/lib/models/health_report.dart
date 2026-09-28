import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// 本機自填的完整 Health Report —— 含 Detail Tier 欄位（姓名、電話、血型、自由文字、
/// 精確座標）。這份資料只走「Reporter 對後端的自願揭露」路徑（Firestore `health_reports`）
/// 與自己的畫面，**不會**原樣進入 BLE 廣播；廣播出去的是 [BroadcastHealthReport] 對應的
/// Broadcast Tier（見 ADR-0003）。
class HealthReport {
  final String id;          // UUID v4，管理端追蹤用唯一識別碼
  final String reporterId;  // 回報者 ID
  final String name;        // 回報者姓名
  final String phone;       // 聯絡電話
  final String? bloodType;  // 血型（可選）
  final String status;      // 健康狀態：'安全' / '輕傷' / '重傷'
  final String? description; // 補充說明（可選）
  final double? lat;         // 緯度（可選）
  final double? lng;         // 經度（可選）
  final DateTime reportTime; // 回報時間

  HealthReport({
    String? id,
    required this.reporterId,
    required this.name,
    required this.phone,
    this.bloodType,
    required this.status,
    this.description,
    this.lat,
    this.lng,
    required this.reportTime,
  }) : id = id ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'reporterId': reporterId,
        'name': name,
        'phone': phone,
        'bloodType': bloodType,
        'status': status,
        'description': description,
        'lat': lat,
        'lng': lng,
        // 一律存 UTC（結尾帶 Z）。存本地時間的字串沒有時區資訊，不同時區的裝置
        // 混在同一個 collection 裡就無法比較先後，字典序也不再等於時間序。
        'reportTime': reportTime.toUtc().toIso8601String(),
      };

  factory HealthReport.fromJson(Map<String, dynamic> json) => HealthReport(
        id: json['id'] as String?,
        reporterId: json['reporterId'] as String,
        name: json['name'] as String,
        phone: json['phone'] as String,
        bloodType: json['bloodType'] as String?,
        status: json['status'] as String,
        description: json['description'] as String?,
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
        // 舊文件是沒有時區的本地時間字串，parse 後當成本地時間；帶 Z 的新文件
        // 會解析成 UTC，這裡統一轉回本地時間再交給 UI。
        reportTime: DateTime.parse(json['reportTime'] as String).toLocal(),
      );
}

/// 從 BLE 廣播收到的 Health Report —— 只有 Broadcast Tier。
///
/// 與本機自填的 [HealthReport] 是**不同來源**：這裡永遠沒有真實姓名、電話、血型、
/// 自由文字或精確座標。UI 不得假設收到的回報帶有這些欄位；聯絡資訊須另行透過
/// Detail Tier 請求（A2，見 ADR-0003）。
class BroadcastHealthReport {
  /// 不具識別性的固定長度識別碼，不可反推回帳號或 Firestore 文件。
  final String reporterHandle;

  /// '安全' / '輕傷' / '重傷'。
  final String status;

  /// 降精度 geohash；無位置時為 null。
  final String? geohash;

  /// 由 [geohash] 還原的近似座標；無位置時為 null。
  final double? approxLat;
  final double? approxLng;

  final DateTime reportTime;

  const BroadcastHealthReport({
    required this.reporterHandle,
    required this.status,
    this.geohash,
    this.approxLat,
    this.approxLng,
    required this.reportTime,
  });
}
