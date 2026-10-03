import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/chat_peer.dart';
import 'chat_message_tile.dart' show ChatPalette;
import 'favorite_star_button.dart';

/// 「附近的人」：目前 mesh 上的 peer 列表（#53），由聊天室 AppBar 的線上人數打開。
///
/// 只負責顯示 [peerList]（`ChatService.peerList`），打開期間 peer 加入、離開、訊號或我的最愛變化
/// 都會即時更新。順序、名稱、`#abcd`、直連／轉傳、訊號格數、我的最愛星號與附在最後的離線最愛都照
/// 原生算好的值顯示（見 `models/chat_peer.dart`），這裡不排序、不判斷門檻。
class PeerListSheet extends StatelessWidget {
  const PeerListSheet({super.key, required this.peerList, this.onPeerTap, this.onFavoriteToggle});

  final ValueListenable<ChatPeerList?> peerList;

  /// 點選某一列時呼叫（聊天室用來開啟與該 peer 的私訊，#55）；null 時列表項目不可點。
  final ValueChanged<ChatPeer>? onPeerTap;

  /// 按下某一列尾端的星號時呼叫（切換我的最愛，#58）；null 時星號只顯示、不能按。
  final ValueChanged<ChatPeer>? onFavoriteToggle;

  static const _bg = Color(0xFFF7F3EC);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _accent = Color(0xFF9B88B3);

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
        child: ValueListenableBuilder<ChatPeerList?>(
          valueListenable: peerList,
          builder: (context, list, _) {
            final peers = list?.peers ?? const <ChatPeer>[];
            return Column(
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
                Row(
                  children: [
                    const Icon(Icons.people_alt_outlined, color: _accent, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      list == null ? '附近的人' : '附近的人（${list.onlineCount}）',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _textPrimary),
                    ),
                  ],
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
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: peers.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFFE8E0D5)),
                      itemBuilder: (context, index) {
                        final peer = peers[index];
                        final onTap = onPeerTap;
                        final onFavorite = onFavoriteToggle;
                        return PeerListTile(
                          key: ValueKey(peer.peerID),
                          peer: peer,
                          onTap: onTap == null ? null : () => onTap(peer),
                          onFavoriteToggle: onFavorite == null ? null : () => onFavorite(peer),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
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
