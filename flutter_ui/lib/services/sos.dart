import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/health_report.dart' show statusUndeclared;
import 'mutual_aid_tasks.dart' show mutualAidInjuries;

/// 舉起 SOS 時送出的 Status（ADR-0004）：最近一次是輕傷／重傷就沿用；從未回報過、或最近一次是
/// 安全（安全不能帶 SOS），送「未宣告」。
String sosStatusFor(String? lastStatus) =>
    mutualAidInjuries.contains(lastStatus) ? lastStatus! : statusUndeclared;

/// 發送端持有的 SOS：Reporter 舉起之後，每一份 Health Report 都帶著它，直到撤回或回報安全
/// （CONTEXT.md 的 SOS）。接收端只看同一 Reporter Handle 最新的一份，所以撤回不需要另外的封包。
class SosState {
  const SosState.lowered() : raisedAt = null;
  const SosState.raisedAt(DateTime this.raisedAt);

  /// 舉起的時間；沒有舉著時為 null。
  final DateTime? raisedAt;

  bool get raised => raisedAt != null;
}

/// 要送出的那一份 Health Report 的 Status 與 SOS 標記。
typedef SosReport = ({String status, bool sos});

/// 一個動作之後的 SOS 狀態，以及隨之要送出的回報。
typedef SosTransition = ({SosState state, SosReport report});

/// SOS 畫面長按送出。已經舉著時再送一次（例如補上位置）不改舉起的時間。
SosTransition raiseSos(SosState current, {required String? lastStatus, required DateTime now}) => (
      state: current.raised ? current : SosState.raisedAt(now),
      report: (status: sosStatusFor(lastStatus), sos: true),
    );

/// Health 畫面回報 [status]：舉著 SOS 時照樣帶著；回報安全就是撤回。
SosTransition reportStatus(SosState current, String status) => status == '安全'
    ? (state: const SosState.lowered(), report: (status: status, sos: false))
    : (state: current, report: (status: status, sos: current.raised));

/// SOS 畫面的「撤回 SOS」。
///
/// 目前 Status 是輕傷／重傷就照送、不帶 SOS。「未宣告」只能和 SOS 同時存在（ADR-0004），撤回時
/// 必須給一個 Status：這時（或從沒有紀錄時）回傳 null，請 Reporter 選好 [chosenStatus] 再呼叫一次。
SosTransition? withdrawSos({required String? currentStatus, String? chosenStatus}) {
  if (chosenStatus != null && chosenStatus != '安全' && !mutualAidInjuries.contains(chosenStatus)) {
    throw ArgumentError.value(chosenStatus, 'chosenStatus', '撤回 SOS 時只能選安全、輕傷或重傷');
  }
  final status = chosenStatus ?? (mutualAidInjuries.contains(currentStatus) ? currentStatus : null);
  if (status == null) return null;
  return (state: const SosState.lowered(), report: (status: status, sos: false));
}

/// SOS 狀態存在本機，App 重啟後仍保留。
///
/// 鍵值比照 `health_status:<uid>` 綁帳號，換帳號登入不會繼承前一個人的 SOS；登出時也和 Status
/// 快取一樣保留（`AccountService.signOut`）。
abstract final class SosStore {
  static String _key(String uid) => 'sos_raised:$uid';

  static Future<SosState> load(String uid) async {
    final raw = (await SharedPreferences.getInstance()).getString(_key(uid));
    final raisedAt = raw == null ? null : DateTime.tryParse(raw);
    return raisedAt == null ? const SosState.lowered() : SosState.raisedAt(raisedAt);
  }

  static Future<void> save(String uid, SosState state) async {
    final prefs = await SharedPreferences.getInstance();
    final raisedAt = state.raisedAt;
    if (raisedAt == null) {
      await prefs.remove(_key(uid));
    } else {
      await prefs.setString(_key(uid), raisedAt.toUtc().toIso8601String());
    }
  }
}

/// SOS 畫面寫 `health_reports/{uid}` 的方式。兩種都以 merge 寫入：文件不存在時照樣建立，
/// 存在時沒列出的欄位保持原樣。
enum CloudSosWrite {
  /// 回報的內容變了：任務回到等待中（`taskStatus`／`helperId`），舊的傷勢細項清掉。
  replace,

  /// 只改 Status、SOS、位置與時間：協助者已經在路上時，舉起或撤回 SOS、補送位置都不該讓
  /// 任務退回等待中（#83）。
  patch,
}

/// Status 改變、或還沒有文件（[previousStatus] 為 null）時整份寫入。另外，已完成（`done`）的
/// 任務又舉起 SOS 時也重新開一筆，否則這次求救不會出現在任何人的待救援清單上。
CloudSosWrite cloudSosWriteFor({
  required String? previousStatus,
  required String status,
  required bool sos,
  String? taskStatus,
}) =>
    previousStatus != status || (sos && taskStatus == 'done') ? CloudSosWrite.replace : CloudSosWrite.patch;

/// 寫進 `health_reports/{uid}` 的欄位（Detail Tier，ADR-0005）。
///
/// Status 一律照寫：本機以為的 Status 可能過期，只改 `sos` 會留下「安全＋SOS」這種救援端查不到
/// 的組合。這次沒有位置時不寫座標——不送假座標，也不把先前回報的真實位置抹成 null。
Map<String, Object?> cloudSosFields(
  CloudSosWrite mode, {
  required ({String id, String name, String area}) reporter,
  required SosReport report,
  required double? lat,
  required double? lng,
  required DateTime now,
}) =>
    {
      'reporterId': reporter.id,
      'status': report.status,
      'sos': report.sos,
      'reportTime': now.toUtc().toIso8601String(),
      if (lat != null && lng != null) ...{'lat': lat, 'lng': lng},
      if (mode == CloudSosWrite.replace) ...{
        'id': const Uuid().v4(),
        'name': reporter.name,
        'area': reporter.area,
        'description': null,
        'taskStatus': 'waiting',
        'helperId': null,
      },
    };

/// 一次 SOS 送出的兩條路各自的結果：經 BLE mesh 廣播給附近裝置，以及寫入雲端（Firestore）。
///
/// 斷網是災害現場的常態：mesh 已送出而雲端逾時，要說「附近裝置已收到」，不能說成失敗。
class SosDelivery {
  const SosDelivery({
    required this.withLocation,
    this.broadcastFailure,
    this.uploadFailure,
    this.uploadQueued = false,
  });

  /// 送出的回報有沒有附上位置。
  final bool withLocation;

  /// 附近廣播沒有送出的原因（給使用者看）；null 表示原生已交給 mesh 廣播。
  final String? broadcastFailure;

  /// 雲端寫入失敗的原因；null 表示已寫入或已暫存（見 [uploadQueued]）。
  final String? uploadFailure;

  /// 離線：寫入已進本機佇列，恢復連線後會自動送出，但伺服器還沒收到。
  final bool uploadQueued;

  /// 兩條路都送到，也附上了位置。
  bool get complete => broadcastFailure == null && uploadFailure == null && !uploadQueued && withLocation;

  /// 兩條路都失敗：這次求救誰都沒收到。
  bool get failed => broadcastFailure != null && uploadFailure != null;

  /// 已經有人收到：mesh 已送出，或雲端已確認。離線暫存還不算——伺服器還沒收到。
  bool get reachedSomeone => broadcastFailure == null || (uploadFailure == null && !uploadQueued);

  /// 離線暫存的上傳之後送到（[failure] 為 null）或失敗了。
  SosDelivery withUpload({String? failure}) => SosDelivery(
        withLocation: withLocation,
        broadcastFailure: broadcastFailure,
        uploadFailure: failure,
      );

  String get message {
    final outcome = switch ((broadcastFailure, uploadFailure)) {
      (null, null) when uploadQueued => '附近裝置已收到求救，雲端尚未上傳，恢復連線後會自動送出。',
      (final broadcast?, null) when uploadQueued => '目前離線，附近廣播也失敗（$broadcast）。求救已暫存，恢復連線後會自動送出。',
      (null, null) => withLocation ? 'SOS 已發送，請保持冷靜等待救援。' : 'SOS 已發送，但沒有附上位置，請設法告知所在地。',
      (final broadcast?, null) => '求救已上傳雲端，但附近廣播失敗（$broadcast）。',
      (null, final upload?) => '附近裝置已收到求救，但雲端上傳失敗（$upload）。',
      (final broadcast?, final upload?) => '發送失敗：附近廣播失敗（$broadcast），雲端上傳也失敗（$upload）。請再試一次。',
    };
    final caveatAlreadySaid = failed || (broadcastFailure == null && uploadFailure == null && !uploadQueued);
    return withLocation || caveatAlreadySaid ? outcome : '$outcome沒有附上位置，請設法告知所在地。';
  }
}
