import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show compute, debugPrint;

import '../bridge/bitchat_bridge.dart';
import '../models/health_report.dart';
import '../protocol/ble_packet_decoder.dart';
import 'health_report_publisher.dart';
import 'mutual_aid_tasks.dart';
import 'sos.dart' show reportResetsTask;

/// 讀取或寫入被 firestore.rules 擋下。
class TaskAccessDenied implements Exception {
  const TaskAccessDenied();

  @override
  String toString() => 'TaskAccessDenied';
}

/// [MutualAidTaskBoard] 與 Firestore 之間的 seam。被規則擋下時以 [TaskAccessDenied] 表示。
abstract interface class MutualAidTaskStore {
  /// 監聽可能成為任務的 `health_reports`（[mutualAidQueryStatuses]）。
  Stream<List<ReportEntry>> watchReports();

  /// [uid] 在 `rescuers` 名單上。讀不到（離線、逾時）時當作不是：詳情畫面頂多少顯示聯絡資訊。
  Future<bool> isVerifiedRescuer(String uid);

  /// 寫回 `health_reports/{reportId}` 的任務進度。
  Future<void> updateTask(String reportId, {required TaskStatus status, required String? helperId});

  /// Reporter 的 `health_report_sensitive` 文件；不存在時回傳 null。
  Future<Map<String, dynamic>?> readSensitive(String reporterUid);
}

class _FirestoreMutualAidTaskStore implements MutualAidTaskStore {
  const _FirestoreMutualAidTaskStore();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  static Object _classify(Object error) =>
      error is FirebaseException && error.code == 'permission-denied' ? const TaskAccessDenied() : error;

  @override
  Stream<List<ReportEntry>> watchReports() => _db
      .collection('health_reports')
      .where('status', whereIn: mutualAidQueryStatuses.toList())
      .snapshots()
      .map((snapshot) => [for (final doc in snapshot.docs) (id: doc.id, data: doc.data())])
      .handleError((Object e) => throw _classify(e));

  @override
  Future<bool> isVerifiedRescuer(String uid) async {
    try {
      final doc = await _db.collection('rescuers').doc(uid).get().timeout(const Duration(seconds: 5));
      return doc.exists;
    } catch (e) {
      debugPrint('load rescuer status failed: $e');
      return false;
    }
  }

  @override
  Future<void> updateTask(String reportId, {required TaskStatus status, required String? helperId}) =>
      _db.collection('health_reports').doc(reportId).update({'taskStatus': status.name, 'helperId': helperId});

  @override
  Future<Map<String, dynamic>?> readSensitive(String reporterUid) async {
    try {
      return (await _db.collection('health_report_sensitive').doc(reporterUid).get()).data();
    } catch (e) {
      throw _classify(e);
    }
  }
}

/// 任務清單讀不到的原因。
enum TaskListError {
  /// 被 firestore.rules 擋下。離線時監聽不會報錯，而是給本機快取，所以多半是這個。
  denied,

  /// 其他錯誤。
  failed,
}

/// 改任務進度的結果。
enum TaskUpdate {
  updated,

  /// Firestore 任務要有帳號才能接：規則要求 helperId 等於登入的 uid。
  signInRequired,

  /// 寫入失敗，例如已被別人接走。
  failed,
}

/// 某一刻的互救任務清單。
class MutualAidTaskList {
  const MutualAidTaskList._({
    required List<ReportEntry> reports,
    required List<BroadcastHealthReport> bleReports,
    required Map<String, TaskStatus> bleProgress,
    required this.loaded,
    required this.error,
  }) : _reports = reports,
       _bleReports = bleReports,
       _bleProgress = bleProgress;

  final List<ReportEntry> _reports;
  final List<BroadcastHealthReport> _bleReports;
  final Map<String, TaskStatus> _bleProgress;

  /// 第一批 Firestore 文件到了（或讀取失敗）。還沒到時清單是空的不代表沒有人需要協助。
  final bool loaded;

  /// Firestore 那一路讀不到的原因；讀得到時為 null。BLE 收到的任務照樣列出。
  final TaskListError? error;

  /// 依自己目前的位置（[lat]／[lng]）排好的任務；沒有定位時距離未知。[currentUserId] 還不知道時不列
  /// 任何 Firestore 任務，免得閃出自己那筆。
  List<MutualAidTask> tasksNear({double? lat, double? lng, String? currentUserId}) => buildMutualAidTasks(
    reports: _reports,
    bleTasks: [for (final report in _bleReports) bleTaskFrom(report, myLat: lat, myLng: lng)],
    currentUserId: currentUserId,
    myLat: lat,
    myLng: lng,
    bleStatusOverrides: _bleProgress,
  );
}

/// 互救任務清單：Firestore 上別人的 Health Report，加上 BLE 收到的匿名回報。
class MutualAidTaskBoard {
  MutualAidTaskBoard({
    MutualAidTaskStore store = const _FirestoreMutualAidTaskStore(),
    Stream<Map<String, dynamic>> Function() events = BitchatBridge.events,
    Future<String> Function()? ownHandle,
    Future<HealthReportPayload?> Function(List<int> payload) decode = _decodeInBackground,
    int bleCapacity = maxBleReports,
  }) : _store = store,
       _events = events,
       _ownHandle = ownHandle ?? HealthReportPublisher.instance.reporterHandle,
       _decode = decode,
       _bleCapacity = bleCapacity;

  /// app 層級的那一份；screen 的建構子可以換成測試替身。
  static final MutualAidTaskBoard instance = MutualAidTaskBoard();

  final MutualAidTaskStore _store;
  final Stream<Map<String, dynamic>> Function() _events;
  final Future<String> Function() _ownHandle;
  final Future<HealthReportPayload?> Function(List<int> payload) _decode;
  final int _bleCapacity;

  StreamSubscription<Map<String, dynamic>>? _collecting;

  /// 每次 [clear] 加一。清除之前收到、清除之後才解碼完的回報不能留下來。
  int _generation = 0;

  /// BLE 收到的回報，每個 Reporter Handle 一份。只放記憶體：寫進磁碟會累積成「誰在何時出現在附近」
  /// 的長期紀錄（ADR-0006 同樣的考量）。
  List<BroadcastHealthReport> _bleReports = const [];

  /// BLE 任務的進度只記在本機：它沒有 Firestore 文件，別人看不到你接了它。
  final Map<String, TaskStatus> _bleProgress = {};

  /// 開著的清單，BLE 那一路有變化時通知它們。
  final Set<void Function()> _watchers = {};

  /// 開始收 BLE 廣播的 Health Report。app 啟動時呼叫一次，之後不必開著清單也照樣收：只在頁面
  /// 開著時收，會漏掉 Rescuer 沒在看清單時經過的回報。可重複呼叫，只有第一次有效。
  void startCollecting() {
    _collecting ??= _events().listen(
      (event) => unawaited(_receive(event)),
      // 沒有原生端的平台（iOS 模擬機、桌機）會丟 MissingPluginException。收不到 BLE 廣播不影響
      // Firestore 那條路，記錄下來就好。
      onError: (Object e) => debugPrint('bitchat bridge stream unavailable: $e'),
    );
  }

  /// 忘掉收到的回報與本機的進度，之後照常收。登出與緊急清除時呼叫：下一個登入的人不該看到前一個人
  /// 接了哪些任務。
  void clear() {
    _generation++;
    _bleReports = const [];
    _bleProgress.clear();
    _notifyWatchers();
  }

  Future<void> _receive(Map<String, dynamic> event) async {
    // 原生端轉來的是原始封包，Flutter 自己解析。
    if (event['type'] != 'packet') return;
    if ((event['packetType'] as num?)?.toInt() != BlePacketType.healthReport) return;
    final payload = event['payload'];
    if (payload is! List) return;
    final generation = _generation;

    final decoded = await _decode(List<int>.from(payload));
    if (decoded == null) return;
    // 不列自己發出的回報（Broadcast Tier 沒有帳號 ID，以 Reporter Handle 比對）。
    if (decoded.reporterHandle == await _ownHandle()) return;
    if (generation != _generation) return;

    final incoming = decoded.toBroadcastReport();
    final previous = _bleReports.where((r) => r.reporterHandle == incoming.reporterHandle).firstOrNull;
    final merged = mergeBleReport(_bleReports, incoming, capacity: _bleCapacity);
    if (identical(merged, _bleReports)) return;
    _reopenIfNeeded(previous, incoming);
    _bleReports = merged;
    // 被擠掉的 Reporter，本機進度也一起忘掉。
    final kept = {for (final report in merged) bleTaskFrom(report, myLat: null, myLng: null).id};
    _bleProgress.removeWhere((id, _) => !kept.contains(id));
    _notifyWatchers();
  }

  /// 較新的回報讓本機進度回到等待中的規則，與 Firestore 任務相同（[reportResetsTask]）：Status 變了，
  /// 或已完成的任務又帶著 SOS。重送相同內容不動，路上的協助者不會丟掉任務。
  void _reopenIfNeeded(BroadcastHealthReport? previous, BroadcastHealthReport incoming) {
    if (previous == null) return;
    final id = bleTaskFrom(incoming, myLat: null, myLng: null).id;
    final progress = _bleProgress[id];
    if (progress == null) return;
    if (reportResetsTask(
      previousStatus: previous.status,
      status: incoming.status,
      sos: incoming.sos,
      taskStatus: progress.name,
    )) {
      _bleProgress.remove(id);
    }
  }

  void _notifyWatchers() {
    for (final watcher in [..._watchers]) {
      watcher();
    }
  }

  /// 監聽任務清單。Firestore 只在有人監聽時讀：頁面關著時不必在背景持續讀整個 collection。
  Stream<MutualAidTaskList> watch() {
    StreamSubscription<List<ReportEntry>>? reportsSubscription;
    var reports = const <ReportEntry>[];
    var loaded = false;
    TaskListError? error;
    late final StreamController<MutualAidTaskList> controller;

    void emit() {
      if (controller.isClosed) return;
      controller.add(
        MutualAidTaskList._(
          reports: reports,
          bleReports: _bleReports,
          bleProgress: Map.unmodifiable(_bleProgress),
          loaded: loaded,
          error: error,
        ),
      );
    }

    controller = StreamController<MutualAidTaskList>(
      onListen: () {
        _watchers.add(emit);
        emit();
        reportsSubscription = _store.watchReports().listen(
          (latest) {
            reports = latest;
            loaded = true;
            error = null;
            emit();
          },
          onError: (Object e) {
            debugPrint('health_reports stream failed: $e');
            loaded = true;
            error = e is TaskAccessDenied ? TaskListError.denied : TaskListError.failed;
            emit();
          },
        );
      },
      onCancel: () async {
        _watchers.remove(emit);
        await reportsSubscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  /// [uid] 是不是 Verified Rescuer，只用來決定詳情畫面怎麼說明，真正的把關在 firestore.rules。
  /// 讀不到時當作不是。
  Future<bool> isVerifiedRescuer(String uid) => _store.isVerifiedRescuer(uid);

  /// 把 [task] 的進度改成 [next]。Firestore 任務寫回文件，讓 Reporter 與其他協助者看到同一份
  /// 進度；BLE 任務沒有文件，只改本機。
  Future<TaskUpdate> updateStatus(MutualAidTask task, TaskStatus next, {required String? currentUserId}) async {
    if (task.isBle) {
      _bleProgress[task.id] = next;
      _notifyWatchers();
      return TaskUpdate.updated;
    }
    if (currentUserId == null) return TaskUpdate.signInRequired;
    try {
      await _store.updateTask(task.id, status: next, helperId: next == TaskStatus.waiting ? null : currentUserId);
      return TaskUpdate.updated;
    } catch (e) {
      debugPrint('updateTaskStatus failed: $e');
      return TaskUpdate.failed;
    }
  }

  /// Reporter 的 Sensitive Tier（電話、血型、病史、緊急聯絡人）。只有正接著這筆任務的 Verified
  /// Rescuer 讀得到（ADR-0005）；被擋下時拋 [TaskAccessDenied]。
  Future<Map<String, dynamic>?> readSensitive(String reporterUid) => _store.readSensitive(reporterUid);
}

/// 在背景 isolate 解碼，避免佔用 UI thread。
Future<HealthReportPayload?> _decodeInBackground(List<int> payload) => compute(_decode, payload);

// compute() 要的是頂層函式。
HealthReportPayload? _decode(List<int> payload) => HealthReportPayload.decode(payload);
