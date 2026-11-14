import 'dart:async';

import 'package:flutter_ui/services/mutual_aid_task_board.dart';
import 'package:flutter_ui/services/mutual_aid_tasks.dart';

/// 記憶體裡的 [MutualAidTaskStore]：測試決定 `health_reports` 監聽收到什麼。
class InMemoryMutualAidTaskStore implements MutualAidTaskStore {
  final StreamController<List<ReportEntry>> _reports = StreamController.broadcast();

  /// 監聽收到這批 `health_reports` 文件。
  void pushReports(List<ReportEntry> reports) => _reports.add(reports);

  /// 監聽收到錯誤，例如規則擋下（[TaskAccessDenied]）。
  void pushReportsError(Object error) => _reports.addError(error);

  bool get watchingReports => _reports.hasListener;

  /// `rescuers` 名單上的 uid。
  Set<String> rescuers = {};

  /// 依序記下每次寫回的任務進度。
  final List<({String reportId, TaskStatus status, String? helperId})> updates = [];

  /// 寫回任務進度時給的錯誤；null 表示成功。
  Object? updateError;

  /// 各 Reporter 的 `health_report_sensitive` 文件。
  Map<String, Map<String, dynamic>> sensitive = {};

  /// 讀 Sensitive Tier 時給的錯誤；null 表示讀得到。
  Object? sensitiveError;

  @override
  Stream<List<ReportEntry>> watchReports() => _reports.stream;

  @override
  Future<bool> isVerifiedRescuer(String uid) async => rescuers.contains(uid);

  @override
  Future<void> updateTask(String reportId, {required TaskStatus status, required String? helperId}) async {
    final error = updateError;
    if (error != null) throw error;
    updates.add((reportId: reportId, status: status, helperId: helperId));
  }

  @override
  Future<Map<String, dynamic>?> readSensitive(String reporterUid) async {
    final error = sensitiveError;
    if (error != null) throw error;
    return sensitive[reporterUid];
  }
}
