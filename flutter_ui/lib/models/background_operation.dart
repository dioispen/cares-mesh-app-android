import 'settings_state.dart';

/// 離開 App 後 Mesh 還會不會繼續運作（P1-6、ADR-0011），對應 Kotlin `MeshBackgroundStatus`
/// （`system_status` 的 `backgroundOperation`，線上名稱 [wireName]）。
///
/// 前景服務沒有在跑時，App 一進背景就可能被系統凍結，附近的人與 Rescuer 就收不到這支手機的
/// Health Report。2026-11-18 試跑時 B 就是這樣，使用者卻不知道。
enum BackgroundOperation {
  /// 前景服務在跑：離開 App 後 Mesh 照常運作。
  active('active'),

  /// 設定裡的「背景執行」關閉了。
  backgroundDisabled('backgroundDisabled'),

  /// 背景執行開著，但缺少前景服務需要的權限（Android 12 起是「附近的裝置」，之前是位置）。
  permissionsMissing('permissionsMissing'),

  /// 設定與權限都沒問題，前景服務卻沒有在跑（例如系統拒絕了啟動）。
  notRunning('notRunning');

  const BackgroundOperation(this.wireName);

  final String wireName;

  static BackgroundOperation? fromWireName(Object? name) {
    for (final operation in values) {
      if (operation.wireName == name) return operation;
    }
    return null;
  }
}

/// `system_status` 裡背景運作的部分。
class BackgroundOperationStatus {
  const BackgroundOperationStatus(this.operation, {this.missingPermission});

  final BackgroundOperation operation;

  /// [BackgroundOperation.permissionsMissing] 時缺的是哪一類權限；原生沒說或這個版本不認得時為 null。
  final SettingsPermissionCategory? missingPermission;

  /// 原生沒有這個欄位（舊版）或值不認得時回傳 null：不知道就不提示。
  static BackgroundOperationStatus? fromSystemStatus(Map<String, dynamic> status) {
    final operation = BackgroundOperation.fromWireName(status['backgroundOperation']);
    if (operation == null) return null;
    final permission = status['backgroundPermission'];
    return BackgroundOperationStatus(
      operation,
      missingPermission: permission is String ? SettingsPermissionCategory.fromWireName(permission) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackgroundOperationStatus &&
      other.operation == operation &&
      other.missingPermission == missingPermission;

  @override
  int get hashCode => Object.hash(operation, missingPermission);
}

/// 首頁提示的修正動作。
enum BackgroundNoticeAction {
  /// 打開設定裡的「背景執行」（原生會跟著啟動前景服務）。
  enableBackground,

  /// 請求缺少的權限：還能詢問就跳出系統詢問，否則開 App 資訊頁。
  requestPermission,

  /// 重新啟動 Mesh 服務。
  restartService,
}

/// 首頁提示的內容。
class BackgroundNotice {
  const BackgroundNotice({required this.title, required this.message, required this.actionLabel, required this.action});

  final String title;
  final String message;
  final String actionLabel;
  final BackgroundNoticeAction action;
}

/// [status] 要顯示的提示；背景運作正常時為 null。
BackgroundNotice? backgroundNoticeFor(BackgroundOperationStatus status) => switch (status.operation) {
      BackgroundOperation.active => null,
      BackgroundOperation.backgroundDisabled => const BackgroundNotice(
          title: '背景執行已關閉',
          message: '離開 App 或關閉螢幕後，系統可能暫停 Mesh，附近的人與救援者就收不到你的求救與回報。',
          actionLabel: '開啟背景執行',
          action: BackgroundNoticeAction.enableBackground,
        ),
      BackgroundOperation.permissionsMissing => BackgroundNotice(
          title: switch (status.missingPermission) {
            final category? => '缺少「${category.label}」權限',
            null => '缺少必要權限',
          },
          message: '沒有這項權限，背景服務無法啟動，離開 App 後 Mesh 就會停止。',
          actionLabel: '授權',
          action: BackgroundNoticeAction.requestPermission,
        ),
      BackgroundOperation.notRunning => const BackgroundNotice(
          title: '背景服務沒有在執行',
          message: '離開 App 或關閉螢幕後，系統可能暫停 Mesh，附近的人與救援者就收不到你的求救與回報。',
          actionLabel: '重新啟動',
          action: BackgroundNoticeAction.restartService,
        ),
    };
