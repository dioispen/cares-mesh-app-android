/// 對話列表的 Dart 端模型（#73）：peer 列表上方「對話」區段的每一列。
///
/// 欄位與 Kotlin `ChatSerialization.conversation` / `conversationsEvent`
/// （`app/src/main/java/com/bitchat/android/flutter/ChatSerialization.kt`、`ChatConversations.kt`）
/// 一一對應，兩邊要一起改。列出哪些對話、順序（原生 `sortConversationSummaries`：在線的在前，
/// 再依置頂、未讀、最近活動、名稱）、名稱、預覽、未讀數、是否在線、星號都由原生
/// `ChatViewModel.conversations` 與 Kotlin 投影層決定；這裡只把 map 轉成型別，不重新排序、
/// 不分組、不推導。被 `/block` 的對象的對話不在裡面（#58）。
///
/// 解析一律容錯、永遠不丟例外：單一欄位型別不符時用預設值；沒有對話 ID 的項目不算對話；
/// 整份快照的外框（`conversations`）不對時整份拒收，讓呼叫端保留現有狀態。
library;

import 'chat_peer.dart' show ChatPeerConnection;

/// 最後一則訊息的種類（原生 `ConversationSummary.latestMessageType`）；圖片、語音、檔案照原生的
/// 字樣顯示。不認得的種類當成文字。
enum ChatConversationPreviewType { message, image, audio, file }

/// 原生私訊紀錄儲存區的狀態（`ChatViewModel.conversationStoreState`）：還在載入或載入失敗時，
/// 空的列表不代表「還沒有對話」，原生區段會照實說。
enum ChatConversationStoreState { loading, ready, error }

/// 一段私訊對話（原生對話列表的一列）。
class ChatConversation {
  const ChatConversation({
    required this.conversationID,
    required this.displayName,
    this.displaySuffix = '',
    this.preview = '',
    this.previewType = ChatConversationPreviewType.message,
    this.previewIsFromSelf = false,
    this.timestamp,
    this.unreadCount = 0,
    this.isOnline = false,
    this.connection = ChatPeerConnection.unknown,
    this.isFavorite = false,
    this.theyFavoritedUs = false,
  });

  /// 原生的對話鍵（通常是 `contact_…`）。點這一列時原樣交給 `chat_startPrivateChat` 開啟對話
  /// （與原生對話列相同），對方離線也能開，原生會載入完整紀錄。
  final String conversationID;

  /// 列上顯示的名稱（原生已切掉 `#abcd`、截斷長度）。
  final String displayName;

  /// 原生名稱的 `#abcd` 後綴（以淡色接在 [displayName] 後）；沒有時是空字串。
  final String displaySuffix;

  /// 最後一則訊息的文字（原生已收合空白、最多 240 字）；可能是空字串。
  final String preview;

  final ChatConversationPreviewType previewType;

  /// 最後一則訊息是我送出的（原生在預覽前加「You:」）。
  final bool previewIsFromSelf;

  /// 最後一則訊息的時間；Kotlin 沒有給時是 null（不顯示時間，不自己編一個）。
  final DateTime? timestamp;

  /// 還沒讀的私訊數（原生對話列上的數字徽章，#56）；沒有時是 0。開啟對話後由原生歸零。
  final int unreadCount;

  /// 原生把這段對話的對象算作在 mesh 上（原生在對方剛斷線時會保留一小段時間，列表不會跳動）。
  /// 缺值時是 false：不猜測對方在線。
  final bool isOnline;

  /// 在線時怎麼連到對方（藍牙直連、Wi-Fi Aware、經 mesh 轉傳）；離線時是
  /// [ChatPeerConnection.offline]。
  final ChatPeerConnection connection;

  /// 我把對方加入了我的最愛（原生對話列頭像上的實心星號，#58）。
  final bool isFavorite;

  /// 對方告訴我們他把我加入了最愛（我沒有加對方時，原生星號是橘色空心）。
  final bool theyFavoritedUs;

  /// 不是 Map、或沒有非空字串的 `conversationID` 時回傳 null；其餘情況一定回傳對話。
  static ChatConversation? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final conversationID = raw['conversationID'];
    if (conversationID is! String || conversationID.isEmpty) return null;
    final displayName = raw['displayName'];
    final displaySuffix = raw['displaySuffix'];
    final preview = raw['preview'];
    final timestamp = raw['timestamp'];
    final unreadCount = raw['unreadCount'];
    return ChatConversation(
      conversationID: conversationID,
      // 只為容錯：列表項目總要有字可顯示。正常資料一定有 displayName。
      displayName: displayName is String && displayName.isNotEmpty ? displayName : conversationID,
      displaySuffix: displaySuffix is String ? displaySuffix : '',
      preview: preview is String ? preview : '',
      previewType: switch (raw['previewType']) {
        'image' => ChatConversationPreviewType.image,
        'audio' => ChatConversationPreviewType.audio,
        'file' => ChatConversationPreviewType.file,
        _ => ChatConversationPreviewType.message,
      },
      previewIsFromSelf: raw['previewIsFromSelf'] == true,
      timestamp: timestamp is int ? DateTime.fromMillisecondsSinceEpoch(timestamp) : null,
      unreadCount: unreadCount is int && unreadCount > 0 ? unreadCount : 0,
      isOnline: raw['isOnline'] == true,
      connection: ChatPeerConnection.fromWire(raw['connection']),
      isFavorite: raw['isFavorite'] == true,
      theyFavoritedUs: raw['theyFavoritedUs'] == true,
    );
  }
}

/// 一份 `chat_conversations` 快照：原生持有的所有私訊對話（在線與離線在同一份清單，依原生的
/// 順序），以及紀錄儲存區的狀態。
class ChatConversationList {
  const ChatConversationList({required this.state, required this.conversations});

  final ChatConversationStoreState state;

  /// 依原生順序；不可修改。
  final List<ChatConversation> conversations;

  /// 解析 `{type: chat_conversations, state, conversations}`。`conversations` 不是 List 時回傳 null；
  /// 清單中不是對話的項目略過、保留其餘順序。`state` 缺值或不認得時當作 [ChatConversationStoreState.ready]。
  static ChatConversationList? fromEvent(Map<String, dynamic> event) {
    final conversations = event['conversations'];
    if (conversations is! List) return null;
    return ChatConversationList(
      state: switch (event['state']) {
        'loading' => ChatConversationStoreState.loading,
        'error' => ChatConversationStoreState.error,
        _ => ChatConversationStoreState.ready,
      },
      conversations: List.unmodifiable([
        for (final entry in conversations) ?ChatConversation.fromMap(entry),
      ]),
    );
  }
}
