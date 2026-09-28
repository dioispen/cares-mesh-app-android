import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:geolocator/geolocator.dart';

/// 互救任務的進度。Firestore 上以 [TaskStatus.name] 存放（waiting / accepted / done）。
enum TaskStatus { waiting, accepted, done }

/// 需要協助的傷勢等級。安全不構成任務。
const mutualAidInjuries = {'輕傷', '重傷'};

/// 互救任務清單上的一筆。
///
/// 不可變：清單是每次重繪從 Firestore 文件與 BLE 封包重新組出來的，
/// 就地改欄位會在 build 期間動到別人持有的物件。
class MutualAidTask {
  final String id;
  final String name;
  final String userId;
  final String injury;
  final String location;

  /// 對方的座標。沒有回報位置時為 null —— 導航按鈕要據此決定能不能按。
  /// BLE 任務放的是 geohash 還原的概略中心，不是精確位置（ADR-0003）。
  final double? lat;
  final double? lng;

  /// 與自己的距離（公里）。自己或對方缺座標時為 null——這與「0 公里」是兩件事。
  final double? distanceKm;
  final String note;
  final TaskStatus status;

  /// 認領這筆任務的協助者 uid；無人認領時為 null。BLE 任務永遠為 null。
  final String? helperId;
  final bool isBle;

  const MutualAidTask({
    required this.id,
    required this.name,
    required this.userId,
    required this.injury,
    required this.location,
    this.lat,
    this.lng,
    required this.distanceKm,
    required this.note,
    this.status = TaskStatus.waiting,
    this.helperId,
    this.isBle = false,
  });

  MutualAidTask copyWith({TaskStatus? status, double? distanceKm}) =>
      MutualAidTask(
        id: id,
        name: name,
        userId: userId,
        injury: injury,
        location: location,
        lat: lat,
        lng: lng,
        distanceKm: distanceKm ?? this.distanceKm,
        note: note,
        status: status ?? this.status,
        helperId: helperId,
        isBle: isBle,
      );

  /// 距離未知時不編故事：顯示「距離未知」而不是 0 公里。
  String get distanceLabel =>
      distanceKm == null ? '距離未知' : '${distanceKm!.toStringAsFixed(1)} km';
}

/// Firestore 文件字串 → [TaskStatus]。
///
/// 認不出來（欄位缺席、舊文件、髒資料）一律當「等待中」，與 firestore.rules 裡
/// `resource.data.get('taskStatus', 'waiting')` 的預設一致。
TaskStatus taskStatusFromRaw(Object? raw) => switch (raw) {
      'accepted' => TaskStatus.accepted,
      'done' => TaskStatus.done,
      _ => TaskStatus.waiting,
    };

/// 一份 `health_reports` 文件的最小輸入形狀。
///
/// 刻意不收 `QueryDocumentSnapshot`，好讓這段排序／過濾邏輯能在沒有 Firebase
/// 的單元測試裡驗證。
typedef ReportEntry = ({String id, Map<String, dynamic> data});

/// 把 Firestore 回報與 BLE 廣播組成互救任務清單。
///
/// 規則：
/// * 只留需要協助的傷勢（[mutualAidInjuries]），安全的回報不是任務。
/// * 排除自己的回報——自己的狀態在「我的狀態」頁，不該出現在待救援清單。
///   [currentUserId] 還沒讀到時一律不顯示任何 Firestore 任務，否則會閃出自己那筆。
/// * BLE 任務的 handle 依設計無法與帳號 ID 連結（ADR-0003），只能在 handle 相同時去重。
/// * 近的排前面，距離未知的排最後——未知不等於 0 公里，不該插隊到最前面。
List<MutualAidTask> buildMutualAidTasks({
  required List<ReportEntry> reports,
  required List<MutualAidTask> bleTasks,
  required String? currentUserId,
  required double? myLat,
  required double? myLng,
  Map<String, TaskStatus> bleStatusOverrides = const {},
}) {
  final tasks = <MutualAidTask>[];

  if (currentUserId != null) {
    for (final report in reports) {
      final data = report.data;
      final reporterId = data['reporterId'] as String?;
      if (reporterId == null || reporterId == currentUserId) continue;

      final injury = data['status'] as String?;
      if (injury == null || !mutualAidInjuries.contains(injury)) continue;

      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final hasLocation = lat != null && lng != null;

      tasks.add(MutualAidTask(
        id: report.id,
        name: (data['name'] as String?)?.trim().isNotEmpty == true
            ? data['name'] as String
            : '未知',
        userId: reporterId,
        injury: injury,
        location: hasLocation
            ? '緯度 ${lat.toStringAsFixed(4)}, 經度 ${lng.toStringAsFixed(4)}'
            : '位置未提供',
        lat: lat,
        lng: lng,
        distanceKm: distanceKmBetween(myLat, myLng, lat, lng),
        note: (data['description'] as String?)?.trim().isNotEmpty == true
            ? data['description'] as String
            : '無補充說明',
        status: taskStatusFromRaw(data['taskStatus']),
        helperId: data['helperId'] as String?,
      ));
    }
  }

  for (final bleTask in bleTasks) {
    if (!mutualAidInjuries.contains(bleTask.injury)) continue;
    if (tasks.any((t) => t.userId == bleTask.userId)) continue;
    tasks.add(bleTask.copyWith(
      status: bleStatusOverrides[bleTask.id] ?? bleTask.status,
    ));
  }

  tasks.sort((a, b) {
    final ad = a.distanceKm;
    final bd = b.distanceKm;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  });
  return tasks;
}

/// 兩點間距離（公里）。任一端缺座標就回 null。
double? distanceKmBetween(
  double? fromLat,
  double? fromLng,
  double? toLat,
  double? toLng,
) {
  if (fromLat == null || fromLng == null || toLat == null || toLng == null) {
    return null;
  }
  return Geolocator.distanceBetween(fromLat, fromLng, toLat, toLng) / 1000;
}

/// 導航到某個座標時，要依序嘗試的 URI。
///
/// 先試該平台原生的地圖 App（救援者手上多半沒有網路，原生 App 至少能開、
/// 也可能有離線圖資），開不起來才退到 Google Maps 的網頁網址。
///
/// 回傳的是「候選清單」而不是單一 URI：launchUrl 對沒安裝的 App 會失敗，
/// 呼叫端要能往下一個試。
List<Uri> navigationUris({
  required double lat,
  required double lng,
  required TargetPlatform platform,
  String? label,
}) {
  final coords = '$lat,$lng';
  final name = (label == null || label.trim().isEmpty) ? null : label.trim();
  return [
    if (platform == TargetPlatform.iOS)
      Uri.parse('maps://?daddr=$coords')
    else if (platform == TargetPlatform.android)
      Uri.parse('geo:$coords?q=${Uri.encodeComponent(coords)}'
          '${name == null ? '' : '(${Uri.encodeComponent(name)})'}'),
    Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$coords'),
  ];
}
