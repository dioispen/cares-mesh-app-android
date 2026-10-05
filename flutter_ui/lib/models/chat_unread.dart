/// 未讀私訊的 Dart 端模型（#56）。
///
/// 欄位與 Kotlin `ChatSerialization.unreadEvent`
/// （`app/src/main/java/com/bitchat/android/flutter/ChatSerialization.kt`、`ChatUnread.kt`）一一對應，
/// 兩邊要一起改。哪些對話算未讀、各有幾則，都由原生 `ChatViewModel` 決定（開啟對話時由原生
/// `startPrivateChat` 清除）；這裡只把 map 轉成型別，不重新推導，也不在 Dart 清除。
///
/// 解析一律容錯、永遠不丟例外：外框不對時整份拒收（回傳 null），讓呼叫端保留現有狀態。
library;

/// 一份 `chat_unread` 快照。
class ChatUnread {
  const ChatUnread({required this.hasUnread, this.conversations = const {}});

  /// 原生端回報前、或沒有任何未讀時。
  static const none = ChatUnread(hasUnread: false);

  /// 原生是否有標為未讀的私訊對話（`ChatViewModel.unreadPrivateMessages` 不是空的）——原生標頭
  /// 顯示「未讀私訊」信封的條件。點信封開啟最新的未讀對話（`ChatService.openLatestUnreadPrivateChat`）。
  final bool hasUnread;

  /// 有未讀的對話（原生對話鍵）→ 未讀數，也就是原生對話列上的數字徽章；只含大於 0 的。
  /// 在線 peer 的未讀數也放在它的 peer 列上（`ChatPeer.unreadCount`）。不可修改。
  final Map<String, int> conversations;

  /// [conversationID] 的未讀數；沒有未讀時是 0。
  int countFor(String conversationID) => conversations[conversationID] ?? 0;

  /// 解析 `{type: chat_unread, hasUnread, conversations}`。`hasUnread` 不是 bool、或
  /// `conversations` 不是 Map 時回傳 null；鍵不是字串、或數量不是正整數的項目略過。
  static ChatUnread? fromEvent(Map<String, dynamic> event) {
    final hasUnread = event['hasUnread'];
    final conversations = event['conversations'];
    if (hasUnread is! bool || conversations is! Map) return null;
    return ChatUnread(
      hasUnread: hasUnread,
      conversations: Map.unmodifiable({
        for (final MapEntry(:key, :value) in conversations.entries)
          if (key is String && value is int && value > 0) key: value,
      }),
    );
  }
}
