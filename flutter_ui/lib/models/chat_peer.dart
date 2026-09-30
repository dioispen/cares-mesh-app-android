/// mesh peer 列表的 Dart 端模型（#53）。
///
/// 欄位與 Kotlin `ChatSerialization.peer` / `peersEvent`
/// （`app/src/main/java/com/bitchat/android/flutter/ChatSerialization.kt`）一一對應，兩邊要一起改。
/// 排序、顯示名稱的後備、`#abcd` 後綴、直連／轉傳、訊號格數與線上人數都由 Kotlin
/// `ChatPeerList` 依原生 peer 列表的規則算好；這裡只把 map 轉成型別，不重新推導。
///
/// 解析一律容錯、永遠不丟例外：單一欄位型別不符時用預設值；沒有 peer ID 的項目不算 peer；
/// 整份快照的外框（`onlineCount`、`peers`）不對時整份拒收，讓呼叫端保留現有狀態。
///
/// 之後的票在這裡加欄位：#58 我的最愛／對方最愛我。
library;

/// 我們如何連到這個 peer（原生的判斷順序：Wi-Fi Aware → 藍牙直連 → 經其他 peer 轉傳）。
enum ChatPeerConnection {
  bluetooth,
  wifiAware,
  routed,

  /// 缺值或不認得的值；不猜測是直連還是轉傳。
  unknown,
}

class ChatPeer {
  const ChatPeer({
    required this.peerID,
    this.nickname,
    required this.displayName,
    this.displaySuffix = '',
    this.rssi,
    this.signalBars,
    this.connection = ChatPeerConnection.unknown,
    this.unreadCount = 0,
  });

  final String peerID;

  /// 對方 announce 的原始暱稱；原生端還沒收到 announce 時為 null。
  final String? nickname;

  /// 列表上顯示的名稱（原生已套用後備、切掉 `#abcd`、截斷長度）。
  final String displayName;

  /// 與別人同名時要顯示的 `#abcd`（以淡色接在 [displayName] 後）；否則是空字串。
  final String displaySuffix;

  /// 訊號強度（dBm）。只有我們直接連到的 peer 才有；轉傳的 peer 為 null。
  final int? rssi;

  /// 0–3 格；[rssi] 為 null 時也是 null。
  final int? signalBars;

  final ChatPeerConnection connection;

  /// 這個 peer 傳來、還沒讀的私訊數（#56）：原生對話列上的數字徽章（它在線時的那個對話）。
  /// 沒有時是 0；開啟對話後由原生歸零。
  final int unreadCount;

  /// 不是 Map、或沒有非空字串的 `peerID` 時回傳 null；其餘情況一定回傳 peer。
  static ChatPeer? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final peerID = raw['peerID'];
    if (peerID is! String || peerID.isEmpty) return null;
    final displayName = raw['displayName'];
    final displaySuffix = raw['displaySuffix'];
    final signalBars = raw['signalBars'];
    final unreadCount = raw['unreadCount'];
    return ChatPeer(
      peerID: peerID,
      nickname: raw['nickname'] is String ? raw['nickname'] as String : null,
      // 只為容錯：列表項目總要有字可顯示。正常資料一定有 displayName。
      displayName: displayName is String && displayName.isNotEmpty ? displayName : peerID,
      displaySuffix: displaySuffix is String ? displaySuffix : '',
      rssi: raw['rssi'] is int ? raw['rssi'] as int : null,
      signalBars: signalBars is int && signalBars >= 0 && signalBars <= 3 ? signalBars : null,
      connection: switch (raw['connection']) {
        'bluetooth' => ChatPeerConnection.bluetooth,
        'wifiAware' => ChatPeerConnection.wifiAware,
        'routed' => ChatPeerConnection.routed,
        _ => ChatPeerConnection.unknown,
      },
      unreadCount: unreadCount is int && unreadCount > 0 ? unreadCount : 0,
    );
  }
}

/// 一份 `chat_peers` 快照：原生標頭的線上人數，加上原生 peer 列表的各列（依顯示順序）。
///
/// 兩者由 Kotlin 從同一個時間點的狀態算出，[onlineCount] 照 Kotlin 給的值，不在這裡重數。
class ChatPeerList {
  const ChatPeerList({required this.onlineCount, required this.peers});

  /// 目前 mesh 上的線上人數（不含自己）。
  final int onlineCount;

  /// 依原生列表順序；不可修改。
  final List<ChatPeer> peers;

  /// 解析 `{type: chat_peers, onlineCount, peers}`。`onlineCount` 不是非負整數、
  /// 或 `peers` 不是 List 時回傳 null；清單中不是 peer 的項目略過、保留其餘順序。
  static ChatPeerList? fromEvent(Map<String, dynamic> event) {
    final onlineCount = event['onlineCount'];
    final peers = event['peers'];
    if (onlineCount is! int || onlineCount < 0 || peers is! List) return null;
    return ChatPeerList(
      onlineCount: onlineCount,
      peers: List.unmodifiable([
        for (final entry in peers) ?ChatPeer.fromMap(entry),
      ]),
    );
  }
}
