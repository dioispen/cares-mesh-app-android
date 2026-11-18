import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../services/announcement_service.dart';
import '../services/mascot_service.dart';

/// 管理中心的廣播紀錄（首頁小喇叭）。
///
/// 像聊天室一樣由舊到新排列、最新的在最下面，保留所有曾經發過的廣播。這個頻道只有管理端
/// 能發言，所以底部沒有輸入框，而是一行說明。
class AnnouncementScreen extends StatefulWidget {
  final String uid;
  final AnnouncementService service;

  AnnouncementScreen({super.key, required this.uid, AnnouncementService? service})
      : service = service ?? AnnouncementService();

  @override
  State<AnnouncementScreen> createState() => _AnnouncementScreenState();
}

class _AnnouncementScreenState extends State<AnnouncementScreen> {
  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _red = Color(0xFFC4553A);
  static const _orange = Color(0xFFBF7A5A);
  static const _purple = Color(0xFF9B88B3);

  late final Stream<List<Announcement>> _stream = widget.service.watch(widget.uid);

  /// 進來之前讀到哪裡：用來畫「以下為新訊息」的分隔線。開啟畫面時讀一次就固定，
  /// 不隨標記已讀而移動，否則分隔線一出現就消失。
  DateTime? _readBefore;
  bool _readBeforeLoaded = false;

  @override
  void initState() {
    super.initState();
    // 廣播頁不顯示小秘書：它會蓋住訊息內容。回到首頁時首頁會自己把小秘書叫回來
    // （didPopNext）。postFrame 避免在 build 期間觸發 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mascotOptionsNotifier.value = const [];
    });
    widget.service.lastRead(widget.uid).then((t) {
      if (mounted) {
        setState(() {
          _readBefore = t;
          _readBeforeLoaded = true;
        });
      }
    });
  }

  void _markRead(List<Announcement> items) {
    if (items.isEmpty) return;
    widget.service.markRead(widget.uid, items.last.createdAt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _textPrimary),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('廣播訊息',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _textPrimary)),
            Text('管理中心發布的公告與通知',
                style: TextStyle(fontSize: 12, color: _textSecondary)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Announcement>>(
              stream: _stream,
              builder: (context, snap) {
                if (snap.hasError) return _errorState(snap.error);
                if (!snap.hasData || !_readBeforeLoaded) {
                  return const Center(child: CircularProgressIndicator(color: _brown));
                }
                final items = snap.data!;
                if (items.isEmpty) return _emptyState();
                WidgetsBinding.instance.addPostFrameCallback((_) => _markRead(items));
                return _messageList(items);
              },
            ),
          ),
          _readOnlyFooter(),
        ],
      ),
    );
  }

  Widget _messageList(List<Announcement> items) {
    // 反向列表：一打開就停在最新一則（最下面），往上滑看較舊的紀錄。
    final rows = <Widget>[];
    var newDividerPlaced = false;
    for (var i = 0; i < items.length; i++) {
      final a = items[i];
      final prev = i > 0 ? items[i - 1] : null;
      if (prev == null || !_sameDay(prev.createdAt, a.createdAt)) {
        rows.add(_dateSeparator(a.createdAt));
      }
      // 第一次打開（從沒讀過）時不畫分隔線：每一則都是新的，畫了也沒意義。
      final isNew = _readBefore != null && a.createdAt.isAfter(_readBefore!);
      if (isNew && !newDividerPlaced) {
        rows.add(_newDivider());
        newDividerPlaced = true;
      }
      rows.add(_bubble(a));
    }
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      children: rows.reversed.toList(),
    );
  }

  Widget _bubble(Announcement a) {
    final levelColor = switch (a.level) {
      'urgent' => _red,
      'important' => _orange,
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(color: _brown, shape: BoxShape.circle),
            child: const Icon(Icons.campaign_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('管理中心',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _textPrimary)),
                    const SizedBox(width: 6),
                    _tag(a.isForEveryone ? '全體廣播' : '只發給你',
                        a.isForEveryone ? _textSecondary : _purple),
                    if (levelColor != null) ...[
                      const SizedBox(width: 4),
                      _tag(a.level == 'urgent' ? '緊急' : '重要', levelColor, filled: true),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                      topLeft: Radius.circular(4),
                    ),
                    border: Border.all(
                      color: levelColor?.withValues(alpha: 0.6) ?? const Color(0xFFE8E0D5),
                      width: levelColor != null ? 1.5 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF3D2C1E).withValues(alpha: 0.04),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (a.title != null) ...[
                        Text(a.title!,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800, color: _textPrimary)),
                        const SizedBox(height: 4),
                      ],
                      SelectableText(a.body,
                          style: const TextStyle(fontSize: 14, height: 1.5, color: _textPrimary)),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Text(_time(a.createdAt),
                            style: const TextStyle(fontSize: 11, color: _textSecondary)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 32),
        ],
      ),
    );
  }

  Widget _tag(String text, Color color, {bool filled = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: filled ? Colors.white : color)),
      );

  Widget _dateSeparator(DateTime t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _brown.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_date(t), style: const TextStyle(fontSize: 11, color: _textSecondary)),
          ),
        ),
      );

  Widget _newDivider() => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(child: Divider(color: _red.withValues(alpha: 0.4))),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('以下為新訊息',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _red)),
            ),
            Expanded(child: Divider(color: _red.withValues(alpha: 0.4))),
          ],
        ),
      );

  Widget _readOnlyFooter() => SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _card,
            border: Border(top: BorderSide(color: _brown.withValues(alpha: 0.1))),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline_rounded, size: 14, color: _textSecondary),
              SizedBox(width: 6),
              Text('此頻道僅供管理中心發布訊息', style: TextStyle(fontSize: 12, color: _textSecondary)),
            ],
          ),
        ),
      );

  Widget _emptyState() => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined, size: 48, color: _textSecondary),
            SizedBox(height: 10),
            Text('目前還沒有廣播訊息', style: TextStyle(fontSize: 15, color: _textSecondary)),
            SizedBox(height: 4),
            Text('管理中心發布公告時會出現在這裡', style: TextStyle(fontSize: 12, color: _textSecondary)),
          ],
        ),
      );

  Widget _errorState(Object? error) {
    final denied = error is FirebaseException && error.code == 'permission-denied';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40, color: _textSecondary),
            const SizedBox(height: 10),
            Text(
              denied ? '目前無法讀取廣播訊息（權限不足）' : '載入廣播訊息失敗，請確認網路後再試',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: _textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _time(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

  static String _date(DateTime t) {
    final now = DateTime.now();
    if (_sameDay(t, now)) return '今天';
    if (_sameDay(t, now.subtract(const Duration(days: 1)))) return '昨天';
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return '${t.year}/${t.month}/${t.day}（${weekdays[t.weekday - 1]}）';
  }
}
