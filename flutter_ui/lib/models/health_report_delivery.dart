import 'package:flutter/services.dart';

import '../bridge/bitchat_bridge.dart';

/// 一份 Health Report 經兩條路送出的結果，只記事實：BLE mesh 向附近廣播 Broadcast Tier，以及把回報
/// 寫進雲端（Firestore）。兩條路互不影響（附近廣播失敗仍會上傳）。給使用者看的說法由畫面決定：在沒有
/// 網路的災害現場，使用者需要知道附近的救援者是不是真的收得到。
class HealthReportDelivery {
  const HealthReportDelivery({
    this.broadcastFailure,
    this.uploadFailure,
    this.uploadQueued = false,
    this.withLocation = true,
  });

  /// 附近廣播沒有送出的原因（給使用者看）；null 表示原生已交給 mesh 廣播。
  final String? broadcastFailure;

  /// 雲端上傳失敗的原因；null 表示已上傳或已暫存（見 [uploadQueued]）。
  final String? uploadFailure;

  /// 離線：上傳已進本機佇列，恢復連線後會自動送出，但伺服器還沒收到。
  final bool uploadQueued;

  /// 送出的回報有沒有附上位置。
  final bool withLocation;

  /// 兩條路都成功。
  bool get complete => broadcastFailure == null && uploadFailure == null && !uploadQueued;

  /// 兩條路都失敗：這份回報誰都沒收到。
  bool get failed => broadcastFailure != null && uploadFailure != null;

  /// 已經有人收到：mesh 已送出，或雲端已確認。離線暫存還不算——伺服器還沒收到。
  bool get reachedSomeone => broadcastFailure == null || (uploadFailure == null && !uploadQueued);

  /// 離線暫存的上傳之後送到（[failure] 為 null）或失敗了。
  HealthReportDelivery withUpload({String? failure}) => HealthReportDelivery(
        broadcastFailure: broadcastFailure,
        uploadFailure: failure,
        withLocation: withLocation,
      );

  /// `BitchatBridge.sendHealthReport` 拋出的 [error] 換成給使用者看的原因。
  static String broadcastFailureReason(Object error) => switch (error) {
        PlatformException(code: HealthReportErrors.serviceNotReady) => 'mesh 尚未啟動',
        PlatformException(code: HealthReportErrors.invalidFormat) => '回報內容格式不符',
        PlatformException(code: HealthReportErrors.sendFailed) => '交給 mesh 時發生錯誤',
        PlatformException(:final code) => '原生錯誤（$code）',
        MissingPluginException() => '此裝置不支援附近廣播',
        _ => '$error',
      };
}

/// 回報 [status] 的結果要怎麼告訴使用者。SOS 的求救有自己的說法（`sosDeliveryMessage`）。
String reportDeliveryMessage(HealthReportDelivery delivery, String status) =>
    switch ((delivery.broadcastFailure, delivery.uploadFailure)) {
      (null, null) when delivery.uploadQueued => '已向附近廣播：$status，目前離線，恢復連線後自動上傳雲端',
      (final broadcast?, null) when delivery.uploadQueued => '已記錄：$status，但附近廣播失敗（$broadcast），目前離線，恢復連線後自動上傳雲端',
      (null, null) => '已回報：$status',
      (final broadcast?, null) => '已上傳雲端，但附近廣播失敗：$broadcast',
      (null, final upload?) => '已向附近廣播：$status，但雲端上傳失敗：$upload',
      (final broadcast?, final upload?) => '回報失敗：附近廣播失敗（$broadcast），雲端上傳也失敗（$upload）',
    };
