import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/background_operation.dart';
import '../services/background_operation_service.dart';

/// 這次開 App 期間被使用者關掉的提示原因；背景運作恢復正常時清除，下次開 App 時也重新開始。
BackgroundOperation? _dismissedReason;

@visibleForTesting
void resetBackgroundNoticeDismissal() => _dismissedReason = null;

/// 首頁的背景運作提示（P1-6、ADR-0013）：前景服務沒有在跑時說明原因，並提供一鍵修正。
///
/// 一直留在首頁，直到問題解決或使用者關掉它；關掉後原因改變（或下次開 App）時再出現。
/// 沒有原生實作（測試、iOS）或原生沒有回報背景運作時什麼都不顯示，也不訂閱事件串流。
/// 狀態在開啟時讀一次，之後跟著原生的 `system_status` 事件與回到 App（`resumed`）更新。
class BackgroundOperationNotice extends StatefulWidget {
  const BackgroundOperationNotice({super.key, this.service, this.padding = EdgeInsets.zero});

  /// 只給測試注入替身。
  final BackgroundOperationService? service;

  /// 顯示時外圍的間距；不顯示時不佔空間。
  final EdgeInsetsGeometry padding;

  /// 修正動作完成後，再讀一次狀態的時間：原生啟動前景服務是非同步的，狀態事件通常會先到。
  static const recheckAfter = Duration(seconds: 1);

  @override
  State<BackgroundOperationNotice> createState() => _BackgroundOperationNoticeState();
}

class _BackgroundOperationNoticeState extends State<BackgroundOperationNotice> {
  static const _accent = Color(0xFFB4652A);
  static const _surface = Color(0xFFFFF4E5);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  late final BackgroundOperationService _service = widget.service ?? BackgroundOperationService();

  BackgroundOperationStatus? _status;
  StreamSubscription<BackgroundOperationStatus?>? _changes;
  AppLifecycleListener? _lifecycle;
  Timer? _recheck;
  bool _fixing = false;

  /// 只採用最新一次讀取的結果。
  int _read = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _lifecycle?.dispose();
    _recheck?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final status = await _load();
    if (!mounted || status == null) return;
    _lifecycle = AppLifecycleListener(onResume: _reload);
    _changes = _service.changes.listen(
      (status) {
        if (status != null) _show(status);
      },
      onError: (Object e) => debugPrint('BackgroundOperationNotice: status events failed: $e'),
    );
  }

  Future<BackgroundOperationStatus?> _load() async {
    final read = ++_read;
    try {
      final status = await _service.load();
      if (mounted && read == _read && status != null) _show(status);
      return status;
    } catch (e) {
      // 讀不到就不提示；下一次事件或回到 App 時再讀。
      debugPrint('BackgroundOperationNotice: cannot read system status: $e');
      return null;
    }
  }

  Future<void> _reload() async {
    await _load();
  }

  void _show(BackgroundOperationStatus status) {
    if (!mounted) return;
    if (status.operation == BackgroundOperation.active) _dismissedReason = null;
    setState(() => _status = status);
  }

  void _dismiss() {
    final status = _status;
    if (status == null) return;
    _dismissedReason = status.operation;
    setState(() {});
  }

  Future<void> _fix(BackgroundOperationStatus status) async {
    setState(() => _fixing = true);
    try {
      await _service.fix(status);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('操作失敗：${e is PlatformException ? (e.message ?? e.code) : e}'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 2),
        ));
      }
    } finally {
      if (mounted) setState(() => _fixing = false);
    }
    _recheck?.cancel();
    _recheck = Timer(BackgroundOperationNotice.recheckAfter, _reload);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null || status.operation == _dismissedReason) return const SizedBox.shrink();
    final notice = backgroundNoticeFor(status);
    if (notice == null) return const SizedBox.shrink();

    return Padding(
      padding: widget.padding,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.warning_amber_rounded, color: _accent, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(notice.title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _textPrimary)),
                  const SizedBox(height: 4),
                  Text(notice.message, style: const TextStyle(fontSize: 13, height: 1.4, color: _textSecondary)),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _fixing ? null : () => _fix(status),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(notice.actionLabel),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _dismiss,
              tooltip: '關閉提示',
              icon: const Icon(Icons.close_rounded, size: 20, color: _textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
