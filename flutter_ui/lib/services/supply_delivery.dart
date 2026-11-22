import 'package:uuid/uuid.dart';

/// 一筆物資申請／捐贈送出後，兩條路各自的結果：經 BLE mesh 廣播給附近裝置，以及寫入雲端
/// （Firestore）。比照 Health Report 的 `SosDelivery`：斷網是災害現場的常態，mesh 已送出而雲端
/// 只是暫存，要說清楚，不能說成失敗。
class SupplyDelivery {
  const SupplyDelivery({
    this.broadcastFailure,
    this.uploadFailure,
    this.uploadQueued = false,
  });

  /// 附近廣播沒有送出的原因（給使用者看）；null 表示原生已交給 mesh 廣播。
  final String? broadcastFailure;

  /// 雲端寫入失敗的原因；null 表示已寫入或已暫存（見 [uploadQueued]）。
  final String? uploadFailure;

  /// 離線：寫入已進本機佇列，恢復連線後會自動送出，但伺服器還沒收到。
  final bool uploadQueued;

  /// 兩條路都送到。
  bool get complete => broadcastFailure == null && uploadFailure == null && !uploadQueued;

  /// 兩條路都失敗：這筆誰都沒收到。
  bool get failed => broadcastFailure != null && uploadFailure != null;

  /// 雲端已寫入或已進離線佇列，這筆已經記下，不用再送。不是的話，畫面保留輸入讓使用者重送，
  /// 重送時沿用同一個 ID：mesh 上已送出的封包和雲端文件才會是同一個 exchangeId，後台去重對得上。
  bool get recorded => uploadFailure == null;

  /// [success] 是成功時的開頭，例如「已送出申請」。
  String message(String success) => switch ((broadcastFailure, uploadFailure)) {
        (null, null) when uploadQueued => '$success：附近裝置已收到，雲端尚未上傳，恢復連線後會自動送出。',
        (final b?, null) when uploadQueued => '目前離線，附近廣播也失敗（$b）。$success已暫存，恢復連線後會自動送出。',
        (null, null) => '$success：已透過 Mesh 廣播給附近裝置，並記錄到雲端。',
        (final b?, null) => '$success：已記錄到雲端，但附近廣播失敗（$b）。',
        (null, final u?) => '$success：附近裝置已收到，但雲端上傳失敗（$u），請再送一次。',
        (final b?, final u?) => '送出失敗：附近廣播失敗（$b），雲端上傳也失敗（$u）。請再試一次。',
      };
}

/// 雲端還沒記下的那一筆所用的 ID（`supply_requests`／`supply_pledges` 的文件 ID，也是 mesh 封包的
/// exchangeId），依物資 ID 分開。重送時沿用同一個：先前已經廣播出去的封包和之後寫進雲端的文件
/// 才會是同一個 exchangeId，後台去重對得上，不會把每次重試都算成一筆離線申請。雲端記下
/// （[SupplyDelivery.recorded]）之後，下一筆換新的 ID。只放記憶體，離開物資頁就重來。
class PendingSubmissionIds {
  PendingSubmissionIds({String Function()? newId}) : _newId = newId ?? const Uuid().v4;

  final String Function() _newId;
  final Map<String, String> _byItem = {};

  String idFor(String itemId) => _byItem[itemId] ??= _newId();

  void settle(String itemId, SupplyDelivery delivery) {
    if (delivery.recorded) _byItem.remove(itemId);
  }
}
