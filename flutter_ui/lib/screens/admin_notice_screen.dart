import 'dart:async';

import 'package:flutter/material.dart';

import '../models/admin_notice.dart';
import '../services/admin_notice_service.dart';
import '../widgets/admin_notice_style.dart';

const _bg = Color(0xFFF7F3EC);
const _card = Color(0xFFFEFDF9);
const _textPrimary = Color(0xFF3D2C1E);
const _textSecondary = Color(0xFF8C7B6E);
const _grey = Color(0xFF9A8F86);

/// 管理端公告列表（#142，docs/ADMIN_NOTICE_V1.md 收件端呈現），從首頁開啟。
///
/// 列出這支手機保留的所有 Admin Notice，新的在前：等級、內容、發布與到期時間，以及「已過期」
/// 「已更正」「已撤回」的標示；已更正、已撤回的不再顯示原內容，已更正的連到更正它的那則。
/// 原生推來新的列表時立刻更新。
///
/// 列表攤開就讀得到全文，所以畫面在前景時，列出來的未讀公告就算讀過了（[AdminNoticeService.markRead]，
/// 定向公告因此寫 readAt 回條，#143）。這次開著的期間它們仍標著「未讀」，使用者分得出哪些是新的。
///
/// [service]、[clock] 只給測試注入替身。
class AdminNoticeScreen extends StatefulWidget {
  const AdminNoticeScreen({super.key, this.service, this.clock});

  final AdminNoticeService? service;

  /// 判斷「已過期」用的時鐘，預設為 [DateTime.now]。
  final DateTime Function()? clock;

  @override
  State<AdminNoticeScreen> createState() => _AdminNoticeScreenState();
}

class _AdminNoticeScreenState extends State<AdminNoticeScreen> {
  late final AdminNoticeService _service = widget.service ?? AdminNoticeService.instance;
  late final AppLifecycleListener _lifecycle;

  /// 這次開著期間看到時還沒讀過的公告，離開畫面前都標著「未讀」。
  final _unreadThisVisit = <String>{};

  /// 已經請原生標成已讀的公告，不重複要求。
  final _markRequested = <String>{};

  /// 每則公告卡片的位置，「查看更正後的公告」靠它捲過去。
  final _cardKeys = <String, GlobalKey>{};

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _service.notices.addListener(_onNotices);
    _rememberUnread(_service.notices.value);
    // 第一個 frame 之後才算「看到」，也才能判斷這個 route 是否在最上面。
    WidgetsBinding.instance.addPostFrameCallback((_) => _markShownRead());
  }

  @override
  void dispose() {
    _service.notices.removeListener(_onNotices);
    _lifecycle.dispose();
    super.dispose();
  }

  void _onNotices() {
    if (!mounted) return;
    setState(() => _rememberUnread(_service.notices.value));
    _markShownRead();
  }

  void _rememberUnread(AdminNoticeList list) {
    for (final notice in list.notices) {
      if (!notice.read) _unreadThisVisit.add(notice.messageId);
    }
  }

  void _onResume() {
    unawaited(_service.refresh());
    _markShownRead();
  }

  /// App 在前景、這個畫面在最上面時，畫面上的未讀公告就是使用者看到了。
  bool get _seenByUser {
    final state = WidgetsBinding.instance.lifecycleState;
    final foreground = state == null || state == AppLifecycleState.resumed;
    return mounted && foreground && (ModalRoute.of(context)?.isCurrent ?? true);
  }

  void _markShownRead() {
    if (!_seenByUser) return;
    for (final notice in _service.notices.value.notices) {
      if (notice.read || !_markRequested.add(notice.messageId)) continue;
      unawaited(_service.markRead(notice.messageId).catchError((Object e) {
        // 下次列表更新或回到前景時再試；未讀數暫時不會減少。
        debugPrint('AdminNoticeScreen: marking ${notice.messageId} read failed: $e');
        _markRequested.remove(notice.messageId);
      }));
    }
  }

  void _showSuccessor(String messageId) {
    final target = _cardKeys[messageId]?.currentContext;
    if (target == null) return;
    unawaited(Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.05,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        surfaceTintColor: _bg,
        foregroundColor: _textPrimary,
        title: const Text('管理端公告', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        top: false,
        child: ValueListenableBuilder<AdminNoticeList>(
          valueListenable: _service.notices,
          builder: (context, list, _) {
            if (list.notices.isEmpty) return const _EmptyList();
            final now = _now();
            // 公告最多幾十則，整份建好，「查看更正後的公告」才捲得到畫面外的卡片。
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final notice in list.notices)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: KeyedSubtree(
                        key: _cardKeys.putIfAbsent(notice.messageId, GlobalKey.new),
                        child: _NoticeCard(
                          key: ValueKey('admin-notice-${notice.messageId}'),
                          notice: notice,
                          unread: _unreadThisVisit.contains(notice.messageId) || !notice.read,
                          expired: notice.isExpiredAt(now),
                          onShowSuccessor: switch (notice.replacedBy) {
                            final successor? when list.byId(successor) != null => () => _showSuccessor(successor),
                            _ => null,
                          },
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    super.key,
    required this.notice,
    required this.unread,
    required this.expired,
    required this.onShowSuccessor,
  });

  final AdminNotice notice;
  final bool unread;
  final bool expired;

  /// 已更正、而且更正它的那則也在列表上時，捲到那一則。
  final VoidCallback? onShowSuccessor;

  @override
  Widget build(BuildContext context) {
    final color = adminNoticeLevelColor(notice.level);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: unread ? color.withValues(alpha: 0.6) : Colors.transparent,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: unread ? 0.18 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AdminNoticeLevelBadge(level: notice.level),
              if (unread) _Tag('未讀', color: color, filled: true),
              if (notice.kind == AdminNoticeKind.targeted) const _Tag('指定給你', color: _textSecondary),
              if (notice.status == AdminNoticeStatus.corrected) const _Tag('已更正', color: _textPrimary),
              if (notice.status == AdminNoticeStatus.withdrawn) const _Tag('已撤回', color: _textPrimary),
              if (expired) const _Tag('已過期', color: _grey),
            ],
          ),
          const SizedBox(height: 10),
          ..._body(),
          const SizedBox(height: 10),
          Text(
            '發布 ${formatAdminNoticeTime(notice.issuedAt)}・有效至 ${formatAdminNoticeTime(notice.expiresAt)}',
            style: const TextStyle(fontSize: 12, color: _textSecondary),
          ),
        ],
      ),
    );
  }

  List<Widget> _body() => switch (notice.status) {
        AdminNoticeStatus.active => [
            Text(
              notice.content,
              style: TextStyle(
                fontSize: 15,
                height: 1.45,
                fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                color: expired ? _textSecondary : _textPrimary,
              ),
            ),
          ],
        AdminNoticeStatus.corrected => [
            const _Hidden('管理員已更正這則公告，原內容不再顯示。'),
            if (onShowSuccessor case final show?)
              TextButton.icon(
                onPressed: show,
                style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: _textPrimary),
                icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                label: const Text('查看更正後的公告', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
          ],
        AdminNoticeStatus.withdrawn => [const _Hidden('管理員已撤回這則公告，請不要再依照原內容行動。')],
      };
}

class _Hidden extends StatelessWidget {
  const _Hidden(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontSize: 14, height: 1.4, fontStyle: FontStyle.italic, color: _textSecondary),
      );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.color, this.filled = false});

  final String text;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color : Colors.transparent,
        border: Border.all(color: color.withValues(alpha: filled ? 1 : 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: filled ? Colors.white : color),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined, size: 52, color: _textSecondary.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            const Text('目前沒有公告', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textPrimary)),
            const SizedBox(height: 6),
            const Text(
              '管理員發布的撤離、收容所開放等公告會顯示在這裡，過期 7 天後自動移除。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: _textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
