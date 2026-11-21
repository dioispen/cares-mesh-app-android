import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bitchat_bridge.dart';
import '../models/health_report.dart';
import '../models/health_report_delivery.dart';
import '../models/health_survey.dart';
import '../models/user.dart';
import 'own_report_cache.dart';
import 'sos.dart' hide raiseSos, withdrawSos;
import 'sos.dart' as sos_rules show raiseSos, withdrawSos;

/// [HealthReportPublisher] 與 Firestore 之間的 seam：自己那兩份文件（ADR-0005）。
abstract interface class HealthReportStore {
  /// 自己的 `health_reports` 文件：先問伺服器，離線時改讀本機快取。文件不存在時回傳空的 map；
  /// 兩邊都讀不到才回傳 null。
  Future<Map<String, dynamic>?> readOwnDetail(String uid);

  /// 自己的 `health_report_sensitive` 文件；讀不到（離線、還沒回報過）時回傳 null。
  Future<Map<String, dynamic>?> readOwnSensitive(String uid);

  /// 監聽自己的 `health_reports` 文件；文件不存在時收到 null。
  Stream<Map<String, dynamic>?> watchOwnDetail(String uid);

  /// 同一個 batch 寫入兩份文件，要嘛一起寫進去，要嘛都沒有。`health_reports` 一律 merge；
  /// `health_report_sensitive` 看 [mergeSensitive]。
  ///
  /// 呼叫當下寫入就進了本機佇列；回傳的 Future 要等伺服器確認才完成，離線時會一直等。
  Future<void> write(
    String uid, {
    required Map<String, Object?> detail,
    required Map<String, Object?> sensitive,
    required bool mergeSensitive,
  });
}

class _FirestoreHealthReportStore implements HealthReportStore {
  const _FirestoreHealthReportStore();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  @override
  Future<Map<String, dynamic>?> readOwnDetail(String uid) async {
    final ref = _db.collection('health_reports').doc(uid);
    for (final read in [
      () => ref.get().timeout(const Duration(seconds: 3)),
      () => ref.get(const GetOptions(source: Source.cache)),
    ]) {
      try {
        final snap = await read();
        return snap.data() ?? <String, dynamic>{};
      } catch (e) {
        debugPrint('read own health report failed: $e');
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> readOwnSensitive(String uid) async {
    try {
      final doc = await _db.collection('health_report_sensitive').doc(uid).get().timeout(const Duration(seconds: 5));
      return doc.data();
    } catch (e) {
      debugPrint('own sensitive survey unavailable: $e');
      return null;
    }
  }

  @override
  Stream<Map<String, dynamic>?> watchOwnDetail(String uid) =>
      _db.collection('health_reports').doc(uid).snapshots().map((doc) => doc.data());

  @override
  Future<void> write(
    String uid, {
    required Map<String, Object?> detail,
    required Map<String, Object?> sensitive,
    required bool mergeSensitive,
  }) =>
      (_db.batch()
            ..set(_db.collection('health_reports').doc(uid), detail, SetOptions(merge: true))
            ..set(_db.collection('health_report_sensitive').doc(uid), sensitive, SetOptions(merge: mergeSensitive)))
          .commit();
}

/// 把一份 Broadcast Tier 交給 mesh；沒有送出時往上拋（[BitchatBridge.sendHealthReport]）。
typedef HealthReportBroadcast =
    Future<void> Function({
      required String reporterHandle,
      required String status,
      required double? lat,
      required double? lng,
      required bool sos,
    });

/// 自己目前的回報，以後端為準。[survey] 已把 Detail Tier 與 Sensitive Tier 兩份併回去（ADR-0007）。
typedef OwnReport = ({String status, String? subInjury, HealthSurvey survey});

/// 一次發布的結果。
class HealthReportPublication {
  const HealthReportPublication({
    required this.delivery,
    required this.status,
    required this.sos,
    this.raisedNow = false,
    this.queuedUpload,
  });

  /// 兩條路各自的結果。[HealthReportDelivery.failed] 時這次發布沒有生效，本機狀態不變。
  final HealthReportDelivery delivery;

  /// 這次送出的 Status。
  final String status;

  /// 發布之後的 SOS 狀態。
  final SosState sos;

  /// 這次發布才舉起 SOS，先前沒有舉著。
  final bool raisedNow;

  /// [HealthReportDelivery.uploadQueued] 時，暫存的上傳之後送到或失敗的結果；不會拋錯。其餘情況為
  /// null。結果要告訴使用者：只留在 log 的話，他會一直以為恢復連線就會送出。
  final Future<HealthReportDelivery>? queuedUpload;
}

/// 一份要寫進雲端的內容，由文件現況決定（[_Current]）。
typedef _CloudWrite = ({Map<String, Object?> detail, Map<String, Object?> sensitive, bool mergeSensitive});

/// 寫入前知道的現況。讀不到文件（離線又沒有快取）時退回本機記得的 Status 與傷勢細項；這時也不知道
/// 任務狀態（[taskStatus] 為 null）。
typedef _Current = ({String? status, String? subInjury, String? taskStatus});

/// 本機記得的 Reporter 狀態。
typedef _Local = ({SosState sos, String? status, String? subInjury});

/// 一位 Reporter 正在進行中的發布。動作可能重疊：調查還在等雲端時，Reporter 可以切到 SOS 畫面舉起
/// SOS。以後發動的動作為準（[started]、[committed]）。
class _ReporterActions {
  /// 已發動的動作數，也是最新動作的序號。
  int started = 0;

  /// 已記進本機的最新動作序號。序號比它舊的動作晚完成時，不能蓋掉較新的狀態。
  int committed = 0;

  /// 還沒完成的動作數。
  int inFlight = 0;

  /// 最新動作完成後的狀態，還在送出中也算：後發動的動作要接著它算，舉起 SOS 還沒送完時送出的調查
  /// 才會帶著 SOS。全部完成後清掉，下一個動作改讀本機保存的狀態，所以沒有人收到的動作不會留下痕跡。
  Future<_Local>? latest;

  /// 前一個動作的雲端寫入已經發出（進了本機佇列）。不等伺服器確認，那在離線時不會完成。
  Future<void> cloudIssued = Future.value();
}

/// Reporter 發布自己的 Health Report：SOS 的轉移（ADR-0004）、經 mesh 廣播 Broadcast Tier、寫進
/// Detail Tier 與 Sensitive Tier（ADR-0005）、記下本機狀態。
///
/// 災難現場可能只有 BLE 沒有網路，也可能有網路但裝置不支援 BLE，所以兩條路互不影響，一條失敗時
/// 另一條照送。兩條都失敗才算沒有發布，本機狀態不變。
class HealthReportPublisher {
  HealthReportPublisher({
    HealthReportStore store = const _FirestoreHealthReportStore(),
    HealthReportBroadcast broadcast = BitchatBridge.sendHealthReport,
    DateTime Function() now = DateTime.now,
    Duration uploadTimeout = const Duration(seconds: 8),
  }) : _store = store,
       _broadcast = broadcast,
       _now = now,
       _uploadTimeout = uploadTimeout;

  /// app 層級的那一份；screen 的建構子可以換成測試替身。
  static final HealthReportPublisher instance = HealthReportPublisher();

  final HealthReportStore _store;
  final HealthReportBroadcast _broadcast;
  final DateTime Function() _now;

  /// 等雲端確認多久，含先讀文件的時間。Firestore 的寫入要等伺服器確認才完成，離線時永遠不會完成
  /// （資料已進本機佇列，恢復連線會自動送出）。使用者不能對著一顆轉不停的按鈕等。
  final Duration _uploadTimeout;

  final Map<String, _ReporterActions> _actions = {};

  /// 監聽中的帳號，Sensitive Tier 那一半調查（`surveySensitive`）。只有本人讀得到，讀一次就留著：
  /// Detail Tier 每次更新都要把它併回去。
  final Map<String, Map<String, dynamic>> _ownSensitiveSurvey = {};

  /// 這次安裝的 Reporter Handle。接收端比對它來過濾自己的回報。
  Future<String> reporterHandle() async => loadOrCreateReporterHandle(await SharedPreferences.getInstance());

  /// 目前的 SOS 狀態，包含還在送出中的動作。
  Future<SosState> sosState(String uid) async => (await _currentLocal(uid)).sos;

  /// 本機記得的 Status 與傷勢細項，包含還在送出中的動作。
  Future<({String? status, String? subInjury})> lastStatus(String uid) async {
    final local = await _currentLocal(uid);
    return (status: local.status, subInjury: local.subInjury);
  }

  /// 監聽自己目前的回報：換裝置或從別的裝置改狀態也會同步過來。後端沒有文件時不發出任何東西，
  /// 也不動本機記得的狀態——寧可留著待確認的傷勢，也不要把回報悄悄降級成「尚未回報」。
  Stream<OwnReport> watchOwnReport(String uid) {
    StreamSubscription<Map<String, dynamic>?>? subscription;
    Map<String, dynamic>? detail;
    late final StreamController<OwnReport> controller;

    void emit() {
      final doc = detail;
      if (doc == null) return;
      final survey = doc['survey'];
      final subInjury = doc['description'] as String?;
      controller.add((
        status: doc['status'] as String,
        subInjury: subInjury,
        survey: HealthSurvey.fromMaps(
          description: subInjury,
          detail: survey is Map ? Map<String, dynamic>.from(survey) : null,
          sensitive: _ownSensitiveSurvey[uid],
        ),
      ));
    }

    Future<void> loadSensitive() async {
      final before = _ownSensitiveSurvey[uid];
      final survey = (await _store.readOwnSensitive(uid))?['surveySensitive'];
      // 讀的這段時間又送出過調查的話，這份已經是舊的。
      if (survey is! Map || controller.isClosed || !identical(_ownSensitiveSurvey[uid], before)) return;
      _ownSensitiveSurvey[uid] = Map<String, dynamic>.from(survey);
      emit();
    }

    controller = StreamController<OwnReport>(
      onListen: () {
        unawaited(loadSensitive());
        subscription = _store.watchOwnDetail(uid).listen((doc) {
          // 文件 ID 是 uid 不代表內容是自己寫的：規則補上「ID 必須是自己 uid」之前，別人可以搶先
          // 建立這份文件。reporterId 對不上就不能當成自己的狀態顯示。
          if (doc == null || doc['reporterId'] != uid || doc['status'] is! String) return;
          detail = doc;
          emit();
          unawaited(OwnStatusCache.save(uid, doc['status'] as String, doc['description'] as String?));
        }, onError: (Object e) => debugPrint('own report stream failed: $e'));
      },
      onCancel: () async {
        _ownSensitiveSurvey.remove(uid);
        await subscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  /// 送出健康回報的狀況調查。[raiseSos]：Reporter 選擇一併舉起 SOS。
  Future<HealthReportPublication> submitSurvey(
    AppUser user, {
    required String status,
    required HealthSurvey survey,
    bool raiseSos = false,
    double? lat,
    double? lng,
  }) async {
    final published = await _publish(
      user,
      lat: lat,
      lng: lng,
      transition: (local) => healthReportTransition(local.sos, status, raise: raiseSos, now: _now()),
      subInjury: (_, _) => survey.injurySummary,
      cloudWrite: (report, current) {
        final full = HealthReport(
          reporterId: user.id,
          name: user.name,
          area: user.area,
          status: report.status,
          description: survey.injurySummary,
          lat: lat,
          lng: lng,
          reportTime: _now(),
          sos: report.sos,
          phone: user.phone,
          bloodType: user.bloodType,
          medicalInfo: user.medicalInfo,
          emergencyContactName: user.emergencyContactName,
          emergencyContactPhone: user.emergencyContactPhone,
          emergencyContactRelation: user.emergencyContactRelation,
          survey: survey,
        );
        final reset = reportResetsTask(
          previousStatus: current.status,
          status: report.status,
          injuryChanged: current.subInjury != survey.injurySummary,
          sos: report.sos,
          taskStatus: current.taskStatus,
        );
        return (
          // toDetailJson() 每個欄位都會寫（含 null），所以 merge 只會保留 taskStatus／helperId。
          detail: {
            ...full.toDetailJson(),
            if (reset) ...{'taskStatus': 'waiting', 'helperId': null},
          },
          sensitive: full.toSensitiveJson(),
          mergeSensitive: false,
        );
      },
    );
    if (!published.delivery.failed) _ownSensitiveSurvey[user.id] = survey.toSensitiveMap();
    return published;
  }

  /// 舉起 SOS：沿用最近一次的傷勢，沒有就是未宣告。已經舉著時舉起的時間不變。
  Future<HealthReportPublication> raiseSos(AppUser user, {double? lat, double? lng}) => _publish(
    user,
    lat: lat,
    lng: lng,
    transition: (local) => sos_rules.raiseSos(local.sos, lastStatus: local.status, now: _now()),
    subInjury: _keepSubInjuryIfStatusUnchanged,
    cloudWrite: (report, current) => _sosWrite(user, report, current, lat: lat, lng: lng),
  );

  /// 剛舉起的 SOS 送出時沒有位置，定位現在回來了：再送一份帶 SOS 的回報補上位置（#81）。
  /// 與再舉起一次相同，舉起的時間不變；Status 不變時雲端只改位置，協助者的認領不受影響。
  Future<HealthReportPublication> addSosLocation(AppUser user, {required double lat, required double lng}) =>
      raiseSos(user, lat: lat, lng: lng);

  /// 撤回 SOS 就是回報安全（[sos_rules.withdrawSos]）。
  Future<HealthReportPublication> withdrawSos(AppUser user, {double? lat, double? lng}) => _publish(
    user,
    lat: lat,
    lng: lng,
    transition: (_) => sos_rules.withdrawSos(),
    subInjury: _keepSubInjuryIfStatusUnchanged,
    cloudWrite: (report, current) => _sosWrite(user, report, current, lat: lat, lng: lng),
  );

  /// SOS 的動作不帶調查：Status 沒變時傷勢細項照舊，變了（例如改成未宣告）就清掉。
  static String? _keepSubInjuryIfStatusUnchanged(_Local local, SosReport report) =>
      report.status == local.status ? local.subInjury : null;

  /// SOS 的動作只改它碰得到的欄位，`survey`／`surveySensitive` 留著（ADR-0007）。
  _CloudWrite _sosWrite(
    AppUser user,
    SosReport report,
    _Current current, {
    required double? lat,
    required double? lng,
  }) => (
    detail: cloudSosFields(
      cloudSosWriteFor(
        previousStatus: current.status,
        status: report.status,
        sos: report.sos,
        taskStatus: current.taskStatus,
      ),
      reporter: (id: user.id, name: user.name, area: user.area),
      report: report,
      lat: lat,
      lng: lng,
      now: _now(),
    ),
    sensitive: cloudSosSensitiveFields(user),
    mergeSensitive: true,
  );

  Future<HealthReportPublication> _publish(
    AppUser user, {
    required double? lat,
    required double? lng,
    required SosTransition Function(_Local local) transition,
    required String? Function(_Local local, SosReport report) subInjury,
    required _CloudWrite Function(SosReport report, _Current current) cloudWrite,
  }) async {
    final uid = user.id;
    final actions = _actions.putIfAbsent(uid, _ReporterActions.new);

    // 到第一個 await 之前都是同步的，所以序號、狀態的接續與雲端的順序都照發動的順序排定。
    final sequence = ++actions.started;
    actions.inFlight++;
    final base = _currentLocal(uid);
    final planned = base.then((before) {
      final next = transition(before);
      final after = (sos: next.state, status: next.report.status, subInjury: subInjury(before, next.report));
      return (before: before, next: next, after: after);
    });
    actions.latest = planned.then((plan) => plan.after, onError: (_) => base)..ignore();
    final previousCloudWrite = actions.cloudIssued;
    final cloudIssued = Completer<void>();
    actions.cloudIssued = cloudIssued.future;

    try {
      final (:before, :next, :after) = await planned;
      final report = next.report;

      final broadcast = _sendBroadcast(report, lat: lat, lng: lng);
      final upload = _upload(uid, before, report, cloudWrite, previousCloudWrite, cloudIssued);
      final uploadResult = _awaitUpload(upload);
      final broadcastFailure = await broadcast;
      final (:queued, :failure) = await uploadResult;
      final delivery = HealthReportDelivery(
        broadcastFailure: broadcastFailure,
        uploadFailure: failure,
        uploadQueued: queued,
        withLocation: lat != null && lng != null,
      );

      if (delivery.failed) {
        return HealthReportPublication(delivery: delivery, status: report.status, sos: before.sos);
      }

      if (sequence > actions.committed) {
        actions.committed = sequence;
        await OwnStatusCache.save(uid, report.status, after.subInjury);
        await SosStore.save(uid, after.sos);
      }

      return HealthReportPublication(
        delivery: delivery,
        status: report.status,
        // 較新的動作發動過的話，要顯示的是它之後的狀態。
        sos: (await actions.latest!).sos,
        raisedNow: !before.sos.raised && next.state.raised,
        queuedUpload: queued
            ? upload.then((_) => delivery.withUpload(), onError: (Object e) => delivery.withUpload(failure: '$e'))
            : null,
      );
    } finally {
      if (!cloudIssued.isCompleted) cloudIssued.complete();
      if (--actions.inFlight == 0) actions.latest = null;
    }
  }

  Future<_Local> _currentLocal(String uid) => _actions[uid]?.latest ?? _readLocal(uid);

  Future<_Local> _readLocal(String uid) async {
    final last = await OwnStatusCache.load(uid);
    return (sos: await SosStore.load(uid), status: last.status, subInjury: last.subInjury);
  }

  /// 交給 mesh；沒有送出時回傳給使用者看的原因。不會拋錯。
  Future<String?> _sendBroadcast(SosReport report, {required double? lat, required double? lng}) async {
    try {
      await _broadcast(
        // BLE 只送 Broadcast Tier：不具識別性的 handle、Status，以及原始座標（由原生端就地降精度為
        // geohash）。姓名／電話／血型／自由文字一律不進入廣播（ADR-0003）。
        reporterHandle: await reporterHandle(),
        status: report.status,
        lat: lat,
        lng: lng,
        sos: report.sos,
      );
      return null;
    } catch (e) {
      debugPrint('Health Report broadcast failed: $e');
      return HealthReportDelivery.broadcastFailureReason(e);
    }
  }

  /// 先讀文件決定怎麼寫，再寫進雲端。排在 [previousCloudWrite] 之後才發出，所以雲端照動作的順序
  /// 寫入；發出後完成 [cloudIssued]，接著等伺服器確認。
  Future<void> _upload(
    String uid,
    _Local before,
    SosReport report,
    _CloudWrite Function(SosReport report, _Current current) cloudWrite,
    Future<void> previousCloudWrite,
    Completer<void> cloudIssued,
  ) async {
    final Future<void> ack;
    try {
      await previousCloudWrite;
      final doc = await _store.readOwnDetail(uid);
      final write = cloudWrite(
        report,
        doc == null
            ? (status: before.status, subInjury: before.subInjury, taskStatus: null)
            : (
                status: doc['status'] as String?,
                subInjury: doc['description'] as String?,
                taskStatus: doc['taskStatus'] as String?,
              ),
      );
      ack = _store.write(uid, detail: write.detail, sensitive: write.sensitive, mergeSensitive: write.mergeSensitive);
    } finally {
      cloudIssued.complete();
    }
    await ack;
  }

  /// 等 [upload] 到逾時為止。逾時後它仍在進行（[HealthReportPublication.queuedUpload]）。
  Future<({bool queued, String? failure})> _awaitUpload(Future<void> upload) async {
    try {
      await upload.timeout(_uploadTimeout);
      return (queued: false, failure: null);
    } on TimeoutException {
      return (queued: true, failure: null);
    } catch (e) {
      debugPrint('Health Report upload failed: $e');
      return (queued: false, failure: '$e');
    }
  }
}
