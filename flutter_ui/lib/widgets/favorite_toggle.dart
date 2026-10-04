import 'package:flutter/material.dart';

import '../services/chat_service.dart';

/// 星號的動作（peer 列表與私訊畫面共用）：交給原生切換 [peerID] 的我的最愛
/// （[ChatService.toggleFavorite]），新的星號隨快照回來，這裡不先改。
///
/// 失敗時記 log（[logTag] 標明是哪個畫面），並在 [context] 還在時以 SnackBar 告知使用者；
/// [context] 是提示要出現的地方（例如還開著的 peer 列表）。
Future<void> toggleFavoriteOrNotify(
  BuildContext context,
  ChatService chat,
  String peerID, {
  required String logTag,
}) async {
  try {
    await chat.toggleFavorite(peerID);
  } catch (e) {
    debugPrint('$logTag: toggleFavorite failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('無法變更我的最愛，請稍後再試')),
      );
    }
  }
}
