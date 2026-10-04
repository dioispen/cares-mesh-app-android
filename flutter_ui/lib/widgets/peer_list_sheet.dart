import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/chat_conversation.dart';
import '../models/chat_peer.dart';
import 'chat_message_tile.dart' show ChatPalette;
import 'favorite_star_button.dart';

/// 由聊天室 AppBar 的線上人數打開的列表，對照原生 `MeshPeerListSheet`：上面是「對話」區段（#73），
/// 下面是「附近的人」區段（#53）。
///
/// - 對話：原生持有的所有私訊對話（[conversations]，`ChatService.conversations`），對方在線與離線
///   在同一份清單、依原生的順序（原生 `sortConversationSummaries`，在線的在前），每列自己標示在線
///   與否——原生再分「在線／離線」兩組，這裡刻意不分組。對方離線、對話已讀、也不是我的最愛時，
///   從這裡仍能開啟。沒有對話時照原生顯示提示（紀錄還在載入或載入失敗時也照實說），不隱藏區段。
/// - 附近的人：目前 mesh 上的 peer（[peerList]，`ChatService.peerList`）。已有對話的 peer 由原生
///   移到上面的對話區段，不在這裡；標題的人數也照原生只算這個區段（`peopleCount`）。
///
/// 打開期間兩個區段都會即時更新。順序、名稱、`#abcd`、連線方式、訊號格數、未讀數與星號都照原生
/// 算好的值顯示（見 `models/chat_conversation.dart`、`models/chat_peer.dart`），這裡不排序、不判斷門檻。
/// 兩個區段來自兩份快照，剛有新對話的那一刻，同一個人可能在兩邊（或都不在）停留一瞬間。
class PeerListSheet extends StatelessWidget {
  const PeerListSheet({
    super.key,
    required this.peerList,
    required this.conversations,
    this.onPeerTap,
    this.onFavoriteToggle,
    this.onConversationTap,
  });

  final ValueListenable<ChatPeerList?> peerList;

  final ValueListenable<ChatConversationList?> conversations;

  /// 點選某一列時呼叫（聊天室用來開啟與該 peer 的私訊，#55）；null 時列表項目不可點。
  final ValueChanged<ChatPeer>? onPeerTap;

  /// 按下某一列尾端的星號時呼叫（切換我的最愛，#58）；null 時星號只顯示、不能按。
  final ValueChanged<ChatPeer>? onFavoriteToggle;

  /// 點選某段對話時呼叫（聊天室用來開啟該私訊，#73）；null 時對話列不可點。
  final ValueChanged<ChatConversation>? onConversationTap;

  static const _bg = Color(0xFFF7F3EC);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _accent = Color(0xFF9B88B3);
  static const _divider = Color(0xFFE8E0D5);

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      decoration: const BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD6CCC2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Flexible(
              child: ValueListenableBuilder<ChatConversationList?>(
                valueListenable: conversations,
                builder: (context, conversationList, _) => ValueListenableBuilder<ChatPeerList?>(
                  valueListenable: peerList,
                  builder: (context, list, _) => ListView(
                    shrinkWrap: true,
                    children: [
                      ..._conversationSection(conversationList),
                      const SizedBox(height: 24),
                      ..._peopleSection(list),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 原生的「對話」區段：標題，再接每段對話；沒有對話時是原生的提示（還沒回報、載入中、失敗或空的）。
  List<Widget> _conversationSection(ChatConversationList? list) {
    final rows = list?.conversations ?? const <ChatConversation>[];
    final onTap = onConversationTap;
    return [
      const _SectionHeader(icon: Icons.mail_outline, title: '對話'),
      const SizedBox(height: 12),
      if (rows.isEmpty)
        _ConversationSectionStatus(state: list?.state)
      else
        for (final (index, conversation) in rows.indexed) ...[
          if (index > 0) const Divider(height: 1, color: _divider),
          ConversationListTile(
            key: ValueKey('conversation:${conversation.conversationID}'),
            conversation: conversation,
            onTap: onTap == null ? null : () => onTap(conversation),
          ),
        ],
    ];
  }

  /// 原生的「附近的人」區段（`PeopleSection`）。
  List<Widget> _peopleSection(ChatPeerList? list) {
    final peers = list?.peers ?? const <ChatPeer>[];
    final peopleCount = list?.peopleCount;
    final onTap = onPeerTap;
    final onFavorite = onFavoriteToggle;
    return [
      _SectionHeader(
        icon: Icons.people_alt_outlined,
        title: peopleCount == null ? '附近的人' : '附近的人（$peopleCount）',
      ),
      const SizedBox(height: 12),
      if (peers.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text(
            '目前沒有人連線',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _textSecondary),
          ),
        )
      else
        for (final (index, peer) in peers.indexed) ...[
          if (index > 0) const Divider(height: 1, color: _divider),
          PeerListTile(
            key: ValueKey(peer.peerID),
            peer: peer,
            onTap: onTap == null ? null : () => onTap(peer),
            onFavoriteToggle: onFavorite == null ? null : () => onFavorite(peer),
          ),
        ],
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: PeerListSheet._accent, size: 22),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PeerListSheet._textPrimary),
          ),
        ],
      );
}

/// 對話區段沒有任何對話時的說明，對照原生 `ConversationSectionStatus`（`loading_conversations`、
/// `conversation_storage_error`、`no_conversations_yet`）。原生端還沒回報時（[state] 為 null）當作載入中。
/// 載入中用靜止的沙漏代替原生的轉圈：通常一閃即過；不停轉的動畫也會讓 widget test 的
/// `pumpAndSettle` 永遠等不到畫面靜止。
class _ConversationSectionStatus extends StatelessWidget {
  const _ConversationSectionStatus({required this.state});

  final ChatConversationStoreState? state;

  @override
  Widget build(BuildContext context) {
    final (Widget icon, String text) = switch (state) {
      null || ChatConversationStoreState.loading => (
          const Icon(Icons.hourglass_top, size: 18, color: PeerListSheet._textSecondary),
          '正在載入私訊對話…',
        ),
      ChatConversationStoreState.error => (
          const Icon(Icons.warning_amber_rounded, size: 18, color: ChatPalette.deliveryFailed),
          '無法載入私訊對話',
        ),
      ChatConversationStoreState.ready => (
          const Icon(Icons.mail_outline, size: 18, color: PeerListSheet._textSecondary),
          '私訊對話會顯示在這裡',
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 10),
          Flexible(
            child: Text(text, style: const TextStyle(fontSize: 13, color: PeerListSheet._textSecondary)),
          ),
        ],
      ),
    );
  }
}

/// 對話列的預覽文字，照原生 `ConversationRow`：圖片、語音、檔案用原生的字樣（`notification_sent_*`
/// 的 zh-TW 字串），空白的文字顯示「…」；最後一則是我送出的時，前面加「你：」（原生
/// `conversation_you_preview`）。
String conversationPreviewText(ChatConversation conversation) {
  final preview = conversation.preview.trim();
  final base = switch (conversation.previewType) {
    ChatConversationPreviewType.image => '📷 傳送了一張圖片',
    ChatConversationPreviewType.audio => '🎤 傳送了一則語音訊息',
    ChatConversationPreviewType.file => preview.isEmpty ? '📎 傳送了一個檔案' : '📎 $preview',
    ChatConversationPreviewType.message => preview.isEmpty ? '…' : preview,
  };
  return conversation.previewIsFromSelf ? '你：$base' : base;
}

/// 對話列上的時間（[at] 相對於 [now]），對照原生的 `DateUtils.getRelativeTimeSpanString`（以分鐘為
/// 最小單位、縮寫）：一分鐘內是「剛剛」，再來是幾分鐘前、幾小時前，跨日後算日曆上的天數（一天是
/// 「昨天」），一週以上顯示日期（不同年加上年份）。對方時鐘較快、時間在未來時也算「剛剛」。
String conversationTimeLabel(DateTime at, DateTime now) {
  final elapsed = now.difference(at);
  if (elapsed < const Duration(minutes: 1)) return '剛剛';
  if (elapsed < const Duration(hours: 1)) return '${elapsed.inMinutes} 分鐘前';
  if (elapsed < const Duration(days: 1)) return '${elapsed.inHours} 小時前';
  // 用 UTC 的日期相減，不受日光節約時間影響。
  final days = DateTime.utc(now.year, now.month, now.day).difference(DateTime.utc(at.year, at.month, at.day)).inDays;
  if (days <= 1) return '昨天';
  if (days < 7) return '$days 天前';
  if (at.year == now.year) return '${at.month}月${at.day}日';
  return '${at.year}/${at.month}/${at.day}';
}

/// 「對話」區段的一列，對照原生 `ConversationRow`：頭像（角落標示在線方式或離線、有關係時的星號）、
/// 名稱（同名的 `#abcd` 淡色；有未讀時粗體）、最後一則預覽與時間、未讀數徽章。
///
/// 在線與否標在頭像角落，與原生相同：在線時是連線方式的圖示（藍牙直連、Wi-Fi Aware、經 mesh 轉傳），
/// 離線是灰色空心圓（原生 `offline_not_in_mesh`「Offline · not in mesh」）。星號只顯示、不能按（原生
/// 對話列也只在頭像上標出；切換我的最愛在私訊畫面標頭）。置頂、靜音、草稿、滑動刪除與標記已讀都
/// 不在這裡（#73 範圍外）。
class ConversationListTile extends StatelessWidget {
  const ConversationListTile({super.key, required this.conversation, this.onTap});

  final ChatConversation conversation;
  final VoidCallback? onTap;

  static const _textPrimary = PeerListSheet._textPrimary;
  static const _textSecondary = PeerListSheet._textSecondary;
  static const _accent = PeerListSheet._accent;

  (IconData, Color, String) get _presence {
    if (!conversation.isOnline) return (Icons.circle_outlined, _textSecondary, '離線 · 不在 mesh 上');
    return switch (conversation.connection) {
      ChatPeerConnection.bluetooth => (Icons.bluetooth, _accent, '在線 · 藍牙直連'),
      ChatPeerConnection.wifiAware => (Icons.wifi, _accent, '在線 · Wi-Fi Aware 直連'),
      ChatPeerConnection.routed => (Icons.alt_route, _accent, '在線 · 經 mesh 轉傳'),
      ChatPeerConnection.offline || ChatPeerConnection.unknown => (Icons.circle, _accent, '在線'),
    };
  }

  Widget? get _star {
    if (!conversation.isFavorite && !conversation.theyFavoritedUs) return null;
    return Icon(conversation.isFavorite ? Icons.star : Icons.star_border, size: 16, color: ChatPalette.favorite);
  }

  @override
  Widget build(BuildContext context) {
    final name = conversation.displayName;
    final (presenceIcon, presenceColor, presenceLabel) = _presence;
    final star = _star;
    final unread = conversation.unreadCount > 0;
    final timestamp = conversation.timestamp;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: ChatPalette.avatarColor(name),
                    child: Text(
                      name.characters.isEmpty ? '?' : name.characters.first,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Tooltip(
                      message: presenceLabel,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(color: PeerListSheet._bg, shape: BoxShape.circle),
                        child: Icon(presenceIcon, size: 12, color: presenceColor),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(
                            text: name,
                            children: [
                              if (conversation.displaySuffix.isNotEmpty)
                                TextSpan(
                                  text: conversation.displaySuffix,
                                  style: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w400),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                            color: _textPrimary,
                          ),
                        ),
                      ),
                      if (star != null) ...[
                        const SizedBox(width: 4),
                        star,
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          conversationPreviewText(conversation),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: _textSecondary),
                        ),
                      ),
                      if (timestamp != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          '· ${conversationTimeLabel(timestamp, DateTime.now())}',
                          maxLines: 1,
                          style: const TextStyle(fontSize: 11, color: _textSecondary),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (unread) ...[
              const SizedBox(width: 8),
              UnreadBadge(count: conversation.unreadCount),
            ],
          ],
        ),
      ),
    );
  }
}

/// peer 列表的一列：暱稱（同名時接淡色 `#abcd`）、連線方式、未讀私訊數、訊號強度、我的最愛星號。
///
/// 未讀數照原生列表放在名稱之後、尾端之前（[UnreadBadge]）。星號（#58）在最尾端，樣子與原生私訊
/// 標頭的星號相同（[FavoriteStarButton]）；原生 peer 列表只在頭像角落標出，這裡讓它也能切換，
/// 與點這一列（開私訊）分開。離線的我的最愛標成「離線最愛」（原生的灰色空心圓），沒有訊號強度。
class PeerListTile extends StatelessWidget {
  const PeerListTile({super.key, required this.peer, this.onTap, this.onFavoriteToggle});

  final ChatPeer peer;
  final VoidCallback? onTap;

  /// 按下星號時呼叫；null 時只在有關係（任一方加了最愛）時顯示不能按的星號。
  final VoidCallback? onFavoriteToggle;

  static const _textPrimary = PeerListSheet._textPrimary;
  static const _textSecondary = PeerListSheet._textSecondary;
  static const _accent = PeerListSheet._accent;

  // 與聊天室頭像同一組顏色、同一個規則（依暱稱），同一個人在兩處顏色一致。
  static const _avatarColors = [
    Color(0xFF6B9EAD),
    Color(0xFF7AA67A),
    Color(0xFFBF7A5A),
    Color(0xFF9B88B3),
  ];

  Color get _avatarColor {
    final key = peer.nickname ?? peer.displayName;
    return _avatarColors[key.hashCode.abs() % _avatarColors.length];
  }

  (IconData, String) get _connection => switch (peer.connection) {
        ChatPeerConnection.bluetooth => (Icons.bluetooth, '藍牙直連'),
        ChatPeerConnection.wifiAware => (Icons.wifi, 'Wi-Fi Aware 直連'),
        ChatPeerConnection.routed => (Icons.alt_route, '經 mesh 轉傳'),
        // 原生 `cd_offline_favorite` 的 zh-TW 字串與灰色空心圓。
        ChatPeerConnection.offline => (Icons.circle_outlined, '離線最愛'),
        ChatPeerConnection.unknown => (Icons.help_outline, '連線方式不明'),
      };

  Widget? get _star {
    final onToggle = onFavoriteToggle;
    if (onToggle != null) {
      return FavoriteStarButton(
        isFavorite: peer.isFavorite,
        theyFavoritedUs: peer.theyFavoritedUs,
        onPressed: onToggle,
        size: 20,
      );
    }
    if (!peer.isFavorite && !peer.theyFavoritedUs) return null;
    return Icon(peer.isFavorite ? Icons.star : Icons.star_border, size: 16, color: ChatPalette.favorite);
  }

  IconData? get _signalIcon => switch (peer.signalBars) {
        3 => Icons.signal_cellular_alt,
        2 => Icons.signal_cellular_alt_2_bar,
        1 => Icons.signal_cellular_alt_1_bar,
        0 => Icons.signal_cellular_0_bar,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final (connectionIcon, connectionLabel) = _connection;
    final name = peer.displayName;
    final rssi = peer.rssi;
    final signalIcon = _signalIcon;
    final star = _star;
    final online = peer.isOnline;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: _avatarColor,
              child: Text(
                name.characters.isEmpty ? '?' : name.characters.first,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text: name,
                      children: [
                        if (peer.displaySuffix.isNotEmpty)
                          TextSpan(
                            text: peer.displaySuffix,
                            style: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w400),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _textPrimary),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(connectionIcon, size: 13, color: online ? _accent : _textSecondary),
                      const SizedBox(width: 4),
                      Text(connectionLabel, style: const TextStyle(fontSize: 12, color: _textSecondary)),
                    ],
                  ),
                ],
              ),
            ),
            if (peer.unreadCount > 0) ...[
              const SizedBox(width: 8),
              UnreadBadge(count: peer.unreadCount),
            ],
            const SizedBox(width: 8),
            if (!online)
              const SizedBox.shrink()
            else if (rssi == null)
              const Tooltip(
                message: '沒有直接連線，無訊號強度',
                child: Text('—', style: TextStyle(fontSize: 12, color: _textSecondary)),
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (signalIcon != null) Icon(signalIcon, size: 16, color: _textPrimary),
                  const SizedBox(width: 4),
                  Text('$rssi dBm', style: const TextStyle(fontSize: 12, color: _textSecondary)),
                ],
              ),
            if (star != null) ...[
              const SizedBox(width: 4),
              star,
            ],
          ],
        ),
      ),
    );
  }
}

/// 未讀私訊數的徽章，對照原生 `MeshPeerListSheet.kt` 的 `UnreadBadge`：強調橘色圓角底、白色粗體
/// 數字，超過 99 顯示 `99+`。[count] 為 0 時不顯示。
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Tooltip(
      message: '$count 則未讀私訊',
      child: Container(
        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: ChatPalette.unread, borderRadius: BorderRadius.circular(10)),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            count > 99 ? '99+' : '$count',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
