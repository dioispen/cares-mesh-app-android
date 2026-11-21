import 'dart:async';

import 'package:flutter_ui/services/health_report_publisher.dart';

/// 記憶體裡的 [HealthReportStore]：寫入照 Firestore 的 merge 語意立刻反映在本機，伺服器確認則由
/// 測試決定（[holdAcks]、[releaseAcks]），用來重現離線暫存與寫入順序。
class InMemoryHealthReportStore implements HealthReportStore {
  /// 自己的 `health_reports` 文件；不存在時是空的 map。
  Map<String, dynamic> detail = {};

  /// 自己的 `health_report_sensitive` 文件。
  Map<String, dynamic> sensitive = {};

  /// 離線又沒有快取：讀不到文件。
  bool unreadable = false;

  /// 每次寫入給的錯誤，例如規則擋下；null 表示寫入成功。
  Object? writeError;

  /// 依發出順序記下每一份寫進 `health_reports` 的欄位。
  final List<Map<String, Object?>> detailWrites = [];

  /// 開著時寫入留在本機，要等 [releaseAcks] 才算伺服器確認。
  bool holdAcks = false;
  final List<Completer<void>> _heldAcks = [];

  /// 開著時 [readOwnDetail] 要等 [releaseReads]，用來重現讀文件比較慢的情況。
  bool holdReads = false;
  final List<Completer<void>> _heldReads = [];

  /// 開著時 [readOwnSensitive] 要等 [releaseSensitiveRead]。
  bool holdSensitiveRead = false;
  final Completer<void> _sensitiveRead = Completer<void>();

  final StreamController<Map<String, dynamic>?> _detailSnapshots = StreamController.broadcast();

  /// 監聽收到自己文件的新內容；文件不存在時是 null。
  void pushDetailSnapshot(Map<String, dynamic>? doc) => _detailSnapshots.add(doc);

  /// 監聽收到錯誤。
  void pushDetailError(Object error) => _detailSnapshots.addError(error);

  bool get hasDetailListener => _detailSnapshots.hasListener;

  void releaseSensitiveRead() => _sensitiveRead.complete();

  void releaseAcks({Object? error}) {
    for (final ack in _heldAcks) {
      error == null ? ack.complete() : ack.completeError(error);
    }
    _heldAcks.clear();
  }

  void releaseReads() {
    for (final read in _heldReads) {
      read.complete();
    }
    _heldReads.clear();
  }

  @override
  Future<Map<String, dynamic>?> readOwnDetail(String uid) async {
    if (holdReads) {
      final read = Completer<void>();
      _heldReads.add(read);
      await read.future;
    }
    return unreadable ? null : Map.of(detail);
  }

  @override
  Future<Map<String, dynamic>?> readOwnSensitive(String uid) async {
    // 伺服器的回應是發出讀取當下的內容，晚到也一樣。
    final response = unreadable ? null : Map.of(sensitive);
    if (holdSensitiveRead) await _sensitiveRead.future;
    return response;
  }

  @override
  Stream<Map<String, dynamic>?> watchOwnDetail(String uid) => _detailSnapshots.stream;

  @override
  Future<void> write(
    String uid, {
    required Map<String, Object?> detail,
    required Map<String, Object?> sensitive,
    required bool mergeSensitive,
  }) {
    final error = writeError;
    if (error != null) return Future.error(error);
    detailWrites.add(detail);
    this.detail = {...this.detail, ...detail};
    this.sensitive = mergeSensitive ? {...this.sensitive, ...sensitive} : Map.of(sensitive);
    if (!holdAcks) return Future.value();
    final ack = Completer<void>();
    _heldAcks.add(ack);
    return ack.future;
  }
}
