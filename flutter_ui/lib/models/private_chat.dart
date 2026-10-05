/// 私訊的 Dart 端模型（#55）。
///
/// 欄位與 Kotlin `ChatSerialization.selectedPrivatePeerEvent` / `privateChatsEvent`
/// （`app/src/main/java/com/bitchat/android/flutter/ChatSerialization.kt`、`ChatPrivateChat.kt`）
/// 一一對應，兩邊要一起改。哪個私訊是「目前選定的」、它叫什麼名字、訊息放在哪個鍵下，都由原生
/// `ChatViewModel` 與 Kotlin 投影層決定；這裡只把 map 轉成型別，不重新推導。
///
/// 解析一律容錯、永遠不丟例外：外框不對時整份拒收（回傳 null），讓呼叫端保留現有狀態。
library;

import 'chat_message.dart';

/// 原生聊天核心目前選定的私訊（`ChatViewModel.selectedPrivateChatPeer`）。
///
/// 原生有選定對象時，它的輸入框文字會送成給這個對象的私訊；私訊畫面就是它的投影。
class PrivateChatFocus {
  const PrivateChatFocus({
    required this.peerID,
    required this.conversationID,
    required this.displayName,
    this.draft = '',
    this.isFavorite = false,
    this.theyFavoritedUs = false,
  });

  /// 原生持有的選定值，原樣保留：送出與草稿都以它標明「這是哪個私訊的輸入框」。
  /// 可能是 mesh peer ID，也可能是原生正規化後的 `contact_…` 對話 ID。
  final String peerID;

  /// 這個對話的訊息在 [PrivateChats] 快照中的鍵（原生對 [peerID] 解析出的正規對話 ID）。
  final String conversationID;

  /// 私訊畫面標題（原生私訊畫面的命名規則；對方離線時仍有名稱）。
  final String displayName;

  /// 原生為這個對話保存的輸入框草稿；沒有時是空字串。
  final String draft;

  /// 我把對方加入了我的最愛（#58）：原生私訊標頭的星號實心橘色。
  final bool isFavorite;

  /// 對方告訴我們他把我加入了最愛（#58）：我沒有加對方時，星號是橘色空心。
  final bool theyFavoritedUs;

  /// 這個對話的訊息：先找 [conversationID]、再找 [peerID]，與原生私訊畫面的查找順序相同
  /// （原生改用新鍵的過渡期間兩者會不同）。都沒有時是空清單。
  List<ChatMessage> messagesIn(Map<String, List<ChatMessage>> chats) =>
      chats[conversationID] ?? chats[peerID] ?? const [];

  @override
  bool operator ==(Object other) =>
      other is PrivateChatFocus &&
      other.peerID == peerID &&
      other.conversationID == conversationID &&
      other.displayName == displayName &&
      other.draft == draft &&
      other.isFavorite == isFavorite &&
      other.theyFavoritedUs == theyFavoritedUs;

  @override
  int get hashCode => Object.hash(peerID, conversationID, displayName, draft, isFavorite, theyFavoritedUs);

  @override
  String toString() => 'PrivateChatFocus($peerID, $displayName)';
}

/// 一份 `chat_selected_private_peer` 事件（也是 `chat_startPrivateChat`／`chat_endPrivateChat`
/// 的回傳值）：[focus] 為 null 表示原生沒有選定私訊，輸入的文字會送到公開聊天室。
class PrivateChatSelection {
  const PrivateChatSelection(this.focus);

  static const none = PrivateChatSelection(null);

  final PrivateChatFocus? focus;

  /// 不是 Map、或 `peerID` 既不是 null 也不是非空字串時回傳 null（格式錯，保留現狀）；
  /// `peerID` 為 null 時回傳 [none]。其餘欄位缺值時用後備：對話鍵用 `peerID`、名稱用 `peerID`
  /// 前 8 字（原生最後的後備也是這樣）、草稿用空字串、星號兩個方向都是 false。
  static PrivateChatSelection? fromEvent(Object? raw) {
    if (raw is! Map) return null;
    final peerID = raw['peerID'];
    if (peerID == null) return none;
    if (peerID is! String || peerID.isEmpty) return null;
    final conversationID = raw['conversationID'];
    final displayName = raw['displayName'];
    final draft = raw['draft'];
    return PrivateChatSelection(PrivateChatFocus(
      peerID: peerID,
      conversationID: conversationID is String && conversationID.isNotEmpty ? conversationID : peerID,
      displayName: displayName is String && displayName.isNotEmpty
          ? displayName
          : peerID.substring(0, peerID.length < 8 ? peerID.length : 8),
      draft: draft is String ? draft : '',
      isFavorite: raw['isFavorite'] == true,
      theyFavoritedUs: raw['theyFavoritedUs'] == true,
    ));
  }
}

/// `chat_private_chats` 快照：對話鍵 → 依原生順序的訊息。
abstract final class PrivateChats {
  /// 不是 Map 或 `chats` 不是 Map 時回傳 null（格式錯，保留現狀）。鍵不是字串、或訊息清單不是
  /// List 的項目略過。回傳的 map 與清單都不可修改。
  static Map<String, List<ChatMessage>>? fromEvent(Object? raw) {
    if (raw is! Map) return null;
    final chats = raw['chats'];
    if (chats is! Map) return null;
    final parsed = <String, List<ChatMessage>>{};
    for (final MapEntry(:key, :value) in chats.entries) {
      final messages = ChatMessage.listFrom(value);
      if (key is String && messages != null) parsed[key] = List.unmodifiable(messages);
    }
    return Map.unmodifiable(parsed);
  }
}
