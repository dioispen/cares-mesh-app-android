import 'package:flutter/services.dart';

import '../bridge/bitchat_bridge.dart';

/// 一次 Health Report 回報的兩條路各自的結果：BLE mesh 向附近廣播 Broadcast Tier，以及把完整回報
/// 上傳雲端（Firestore）。兩條路互不影響（附近廣播失敗仍會上傳），提示要如實反映兩者：在沒有網路的
/// 災害現場，使用者需要知道附近的救援者是不是真的收得到。
class HealthReportDelivery {
  const HealthReportDelivery({this.broadcastFailure, this.uploadFailure});

  /// 附近廣播沒有送出的原因（給使用者看）；null 表示原生已交給 mesh 廣播。
  final String? broadcastFailure;

  /// 雲端上傳失敗的原因；null 表示已上傳。
  final String? uploadFailure;

  /// 兩條路都成功。
  bool get complete => broadcastFailure == null && uploadFailure == null;

  /// 兩條路都失敗：這份回報誰都沒收到。
  bool get failed => broadcastFailure != null && uploadFailure != null;

  /// 給使用者的提示；[status] 是回報的 Status（例如「重傷」）。
  String message(String status) => switch ((broadcastFailure, uploadFailure)) {
        (null, null) => '已回報：$status',
        (final broadcast?, null) => '已上傳雲端，但附近廣播失敗：$broadcast',
        (null, final upload?) => '已向附近廣播：$status，但雲端上傳失敗：$upload',
        (final broadcast?, final upload?) => '回報失敗：附近廣播失敗（$broadcast），雲端上傳也失敗（$upload）',
      };

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
