/// 實機量測工具（#70，debug 限定）的 Dart 端模型：`experiment_getStatus` 回傳的現場狀態、發送器
/// 狀態，以及實驗畫面表單的驗證。
///
/// 欄位與 Kotlin `ExperimentBridge`（`app/src/debug/java/com/bitchat/android/experiment/ExperimentBridge.kt`）
/// 一一對應，兩邊要一起改。解析一律容錯、永遠不丟例外：單一欄位型別不符時當作不知道（null）或
/// 預設值，不自己編一個看似正常的數字；整份回覆不是 Map 時回傳 null，讓呼叫端保留現有狀態。
library;

import 'package:flutter/services.dart';

import '../bridge/bitchat_bridge.dart';

/// 裝置編號與固定實驗 handle：裝置 N 一律以 `ee` 加 N 補零成 10 位（`ee0000000001`～`ee0000000010`）
/// 送 Health Report，接收端依 handle 計數。
abstract final class ExperimentHandles {
  /// 可選的裝置編號（一次實驗最多 10 支手機），與 Kotlin `ExperimentHandles.DEVICES` 一致。
  static const devices = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

  /// 裝置 [device] 的實驗 handle（12 碼 hex）。
  static String forDevice(int device) => 'ee${device.toString().padLeft(10, '0')}';

  /// 所有裝置的 handle，依裝置編號排序。
  static final List<String> all = List.unmodifiable([for (final device in devices) forDevice(device)]);
}

/// 發送器的 TTL：0～7，與 Kotlin `ExperimentPlan.TTL_RANGE` 一致。
abstract final class ExperimentTtl {
  static const min = 0;

  /// `MESSAGE_TTL_HOPS`。
  static const max = 7;

  /// 現行 Health Report 的 TTL。
  static const initial = 3;

  /// [ttl] 最遠能到第幾跳：發送端不扣 TTL、每轉發一次扣 1、到 0 就不再轉發，所以 TTL n 到第 n + 1 跳。
  static String reach(int ttl) => ttl == 0 ? 'TTL 0：只到直連鄰居' : 'TTL $ttl：最遠第 ${ttl + 1} 跳';
}

/// 發送器的狀態（原生 `state`）。
enum ExperimentSenderState {
  idle('閒置'),
  waiting('等待開始'),
  sending('發送中'),
  done('已完成'),
  stopped('已停止'),

  /// 不認得的值（例如原生新增了狀態）：照實說不知道，不當成任何已知狀態。
  unknown('未知');

  const ExperimentSenderState(this.label);

  /// 畫面上的中文名稱。
  final String label;

  /// 等待開始或發送中：這時再按「開始」原生會以 [ExperimentErrors.alreadyRunning] 拒絕。
  bool get isRunning => this == waiting || this == sending;

  static ExperimentSenderState fromWire(Object? raw) => switch (raw) {
        'idle' => idle,
        'waiting' => waiting,
        'sending' => sending,
        'done' => done,
        'stopped' => stopped,
        _ => unknown,
      };
}

/// 發送器狀態（`experiment_startSender`／`experiment_stopSender` 的回傳值，與
/// `experiment_getStatus` 的 `sender`）。
class ExperimentSenderStatus {
  const ExperimentSenderStatus({
    this.state = ExperimentSenderState.idle,
    this.sent = 0,
    this.failed = 0,
    this.written = 0,
    this.noLink = 0,
    this.total = 0,
    this.startsAt,
    this.handle,
    this.ttl,
    this.intervalMs,
    this.keepAwake,
  });

  /// 原生還沒回報發送器時的預設：閒置、沒有排程。
  static const idle = ExperimentSenderStatus();

  final ExperimentSenderState state;

  /// 本次交給 mesh 的筆數。
  final int sent;

  /// 本次 mesh 沒收下（例如服務沒在跑）的筆數。
  final int failed;

  /// 已送出、且 BLE 至少寫出一條鏈路的筆數。廣播沒有回條，這是送出端看得到最接近「有送出去」的訊號。
  final int written;

  /// 已送出、但寫出時沒有任何鏈路（附近沒有連上的手機，沒有人收得到）的筆數。
  final int noLink;

  /// 本次要送的總筆數；閒置時是 0。
  final int total;

  /// 排定的第一筆送出時間（本機時間）；閒置時是 null。
  final DateTime? startsAt;

  /// 本次使用的實驗 handle；閒置時是 null。
  final String? handle;

  /// 本次的 TTL；閒置時是 null。
  final int? ttl;

  /// 本次每筆的間隔（ms）；閒置時是 null。
  final int? intervalMs;

  /// 本次是否持有 wake lock（螢幕關閉也照排程送）；閒置或原生沒給時是 null。
  final bool? keepAwake;

  /// 不是 Map 時回傳 null；其餘情況一定回傳狀態。
  static ExperimentSenderStatus? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final startsAtMs = raw['startsAtMs'];
    final handle = raw['handle'];
    final keepAwake = raw['keepAwake'];
    return ExperimentSenderStatus(
      state: ExperimentSenderState.fromWire(raw['state']),
      sent: _count(raw['sent']) ?? 0,
      failed: _count(raw['failed']) ?? 0,
      written: _count(raw['written']) ?? 0,
      noLink: _count(raw['noLink']) ?? 0,
      total: _count(raw['total']) ?? 0,
      startsAt: startsAtMs is int ? DateTime.fromMillisecondsSinceEpoch(startsAtMs) : null,
      handle: handle is String && handle.isNotEmpty ? handle : null,
      ttl: _count(raw['ttl']),
      intervalMs: _count(raw['intervalMs']),
      keepAwake: keepAwake is bool ? keepAwake : null,
    );
  }
}

/// 一份 `experiment_getStatus` 回覆：現場即時計數畫面顯示的全部數據。
class ExperimentStatus {
  const ExperimentStatus({
    this.links,
    this.powerMode,
    this.systemPowerSave,
    this.peerId,
    this.rx20s = const {},
    this.rx60s = const {},
    this.sender = ExperimentSenderStatus.idle,
  });

  /// 目前直連數；原生沒給（或型別不符）時是 null，畫面顯示不知道，不顯示 0。
  final int? links;

  /// app 目前的 `PowerManager.PowerMode`（原樣，例如 `BALANCED`）；中文見 [powerModeLabel]。
  /// 它只看前景／背景、充電與電量，**不受系統省電模式影響**，系統省電見 [systemPowerSave]。
  final String? powerMode;

  /// Android 系統省電模式是否開著；原生沒給（或型別不符）時是 null。開著會限制背景與掃描，
  /// 除了刻意測它的實驗以外都要關掉。
  final bool? systemPowerSave;

  /// 本機 mesh peerID 前 8 碼；mesh 沒在跑時是 null。
  final String? peerId;

  /// 最近 20 s 內依實驗 handle 統計的 `RX` 筆數；沒列出的 handle 是 0。不可修改。
  final Map<String, int> rx20s;

  /// 最近 60 s 內依實驗 handle 統計的 `RX` 筆數；沒列出的 handle 是 0。不可修改。
  final Map<String, int> rx60s;

  final ExperimentSenderStatus sender;

  /// 接收計數表的列：所有裝置的 handle 依序列出（沒收到時是 0），再接原生計到、但不在其中的
  /// handle（依字母序），一筆都不漏。
  List<String> get rxHandles {
    final extra = {...rx20s.keys, ...rx60s.keys}.difference(ExperimentHandles.all.toSet()).toList()..sort();
    return [...ExperimentHandles.all, ...extra];
  }

  /// 不是 Map 時回傳 null；其餘情況一定回傳狀態。
  static ExperimentStatus? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final links = raw['links'];
    final powerMode = raw['powerMode'];
    final systemPowerSave = raw['systemPowerSave'];
    final peerId = raw['peerId'];
    return ExperimentStatus(
      links: links is int && links >= 0 ? links : null,
      powerMode: powerMode is String && powerMode.isNotEmpty ? powerMode : null,
      systemPowerSave: systemPowerSave is bool ? systemPowerSave : null,
      peerId: peerId is String && peerId.isNotEmpty ? peerId : null,
      rx20s: _counts(raw['rx20s']),
      rx60s: _counts(raw['rx60s']),
      sender: ExperimentSenderStatus.fromMap(raw['sender']) ?? ExperimentSenderStatus.idle,
    );
  }
}

/// 電源模式的中文名稱；不認得時回傳 null（畫面只顯示原值）。
String? powerModeLabel(String mode) => switch (mode) {
      'PERFORMANCE' => '效能',
      'BALANCED' => '平衡',
      'POWER_SAVER' => '省電',
      'ULTRA_LOW_POWER' => '極省電',
      _ => null,
    };

/// 實驗畫面發送器表單的驗證：通過的值才交給原生（`BitchatBridge.startExperimentSender`）。
abstract final class ExperimentSenderInput {
  /// 原生以 32-bit int 接收，超過的數字一律不合法。
  static const _maxNativeInt = 0x7fffffff;

  static final _startAt = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})$');

  /// 筆數 N：至少 1 的整數；不合法時回傳 null。
  static int? parseCount(String text) {
    final count = _wholeNumber(text);
    return count != null && count >= 1 ? count : null;
  }

  /// 間隔（ms）：0 以上的整數（0 為突發測試）；不合法時回傳 null。
  static int? parseIntervalMs(String text) => _wholeNumber(text);

  /// 開始時間：空白表示立即開始（`startAt` 為 null）；否則必須是 `H:mm:ss` 或 `HH:mm:ss` 的
  /// 24 小時制時間（全形冒號也可），一律補成 `HH:mm:ss`。
  static ({bool valid, String? startAt}) parseStartAt(String text) {
    final trimmed = text.trim().replaceAll('：', ':');
    if (trimmed.isEmpty) return (valid: true, startAt: null);
    final match = _startAt.firstMatch(trimmed);
    if (match == null) return (valid: false, startAt: null);
    final [hour, minute, second] = [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
    if (hour > 23 || minute > 59 || second > 59) return (valid: false, startAt: null);
    return (valid: true, startAt: [hour, minute, second].map(_twoDigits).join(':'));
  }

  static int? _wholeNumber(String text) {
    final trimmed = text.trim();
    if (!RegExp(r'^\d+$').hasMatch(trimmed)) return null;
    final value = int.tryParse(trimmed);
    return value != null && value <= _maxNativeInt ? value : null;
  }
}

/// 排定開始時間的顯示：「今天 14:30:05」「明天 09:00:00」「昨天 …」，其他日期為
/// `yyyy-MM-dd HH:mm:ss`。原生把已過的 `HH:mm:ss` 排到明天，標出日子才看得出時間打錯。
String formatExperimentStart(DateTime startsAt, DateTime now) {
  final time = [startsAt.hour, startsAt.minute, startsAt.second].map(_twoDigits).join(':');
  final day = switch (_dayDifference(startsAt, now)) {
    0 => '今天',
    1 => '明天',
    -1 => '昨天',
    _ => '${startsAt.year}-${_twoDigits(startsAt.month)}-${_twoDigits(startsAt.day)}',
  };
  return '$day $time';
}

/// [startsAt] 與 [now] 是同一個日曆日。
bool experimentStartsToday(DateTime startsAt, DateTime now) => _dayDifference(startsAt, now) == 0;

/// 距離開始的倒數 `H:mm:ss`（無條件進位到秒，所以到 0 那一刻就是開始）；已經開始時回傳 null。
String? formatExperimentCountdown(DateTime startsAt, DateTime now) {
  final remainingMs = startsAt.difference(now).inMilliseconds;
  if (remainingMs <= 0) return null;
  final seconds = (remainingMs + 999) ~/ 1000;
  return '${seconds ~/ 3600}:${_twoDigits(seconds ~/ 60 % 60)}:${_twoDigits(seconds % 60)}';
}

/// 實驗 method 拋出的 [error] 換成給操作者看的原因。
String experimentErrorReason(Object error) => switch (error) {
      PlatformException(code: ExperimentErrors.invalidArgument) => '參數不合法',
      PlatformException(code: ExperimentErrors.serviceNotReady) => 'mesh 服務未啟動',
      PlatformException(code: ExperimentErrors.alreadyRunning) => '發送器已在執行，請先停止',
      PlatformException(:final code) => '原生錯誤（$code）',
      MissingPluginException() => '原生端沒有實驗工具（不是 debug build？）',
      _ => '$error',
    };

/// 0 以上的 int；其他（含負數）回傳 null。
int? _count(Object? raw) => raw is int && raw >= 0 ? raw : null;

/// `{handle: count}`：鍵不是字串、值不是 0 以上 int 的項目略過，其餘保留。
Map<String, int> _counts(Object? raw) {
  if (raw is! Map) return const {};
  return Map.unmodifiable({
    for (final MapEntry(:key, :value) in raw.entries)
      if (key is String && _count(value) != null) key: value as int,
  });
}

/// 兩個時間相差幾個日曆日（以日期計，不受夏令時間影響）。
int _dayDifference(DateTime a, DateTime b) =>
    DateTime.utc(a.year, a.month, a.day).difference(DateTime.utc(b.year, b.month, b.day)).inDays;

String _twoDigits(int n) => n.toString().padLeft(2, '0');
