import 'package:flutter/material.dart';

import '../models/admin_notice.dart';

/// 公告列表與首頁公告卡片共用的等級配色、圖示與時間寫法。

/// 緊急用 SOS 的紅、重要用琥珀、資訊用避難所的藍，與首頁其他卡片同一組色調。
Color adminNoticeLevelColor(AdminNoticeLevel level) => switch (level) {
      AdminNoticeLevel.urgent => const Color(0xFFC4553A),
      AdminNoticeLevel.important => const Color(0xFFC98A2E),
      AdminNoticeLevel.info => const Color(0xFF6B9EAD),
    };

IconData adminNoticeLevelIcon(AdminNoticeLevel level) => switch (level) {
      AdminNoticeLevel.urgent => Icons.warning_rounded,
      AdminNoticeLevel.important => Icons.campaign_rounded,
      AdminNoticeLevel.info => Icons.info_rounded,
    };

/// 本地時間的 `M/d HH:mm`。公告會保留到過期後 7 天，所以一律帶日期。
String formatAdminNoticeTime(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

/// 等級標籤：圖示加「緊急」「重要」「資訊」。
class AdminNoticeLevelBadge extends StatelessWidget {
  const AdminNoticeLevelBadge({super.key, required this.level, this.onDark = false});

  final AdminNoticeLevel level;

  /// 放在等級色的底上（首頁卡片）時改用白字。
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final color = adminNoticeLevelColor(level);
    final foreground = onDark ? Colors.white : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: onDark ? Colors.white.withValues(alpha: 0.2) : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(adminNoticeLevelIcon(level), size: 14, color: foreground),
          const SizedBox(width: 4),
          Text(level.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: foreground)),
        ],
      ),
    );
  }
}
