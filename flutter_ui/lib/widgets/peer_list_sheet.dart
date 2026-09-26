import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/chat_peer.dart';

/// 「附近的人」：目前 mesh 上的 peer 列表（#53），由聊天室 AppBar 的線上人數打開。
///
/// 只負責顯示 [peerList]（`ChatService.peerList`），打開期間 peer 加入、離開或訊號變化都會即時更新。
/// 順序、名稱、`#abcd`、直連／轉傳與訊號格數都照原生算好的值顯示（見 `models/chat_peer.dart`），
/// 這裡不排序、不判斷門檻。
class PeerListSheet extends StatelessWidget {
  const PeerListSheet({super.key, required this.peerList, this.onPeerTap});

  final ValueListenable<ChatPeerList?> peerList;

  /// 點選某一列時呼叫；null 時列表項目不可點。#55 在這裡接上「開私訊」。
  final ValueChanged<ChatPeer>? onPeerTap;

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
                        return PeerListTile(
                          key: ValueKey(peer.peerID),
                          peer: peer,
                          onTap: onTap == null ? null : () => onTap(peer),
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

/// peer 列表的一列：暱稱（同名時接淡色 `#abcd`）、連線方式、訊號強度。
///
/// 之後的欄位（#56 未讀數、#58 我的最愛）加在名稱列或尾端，[onTap] 由 #55 接上「開私訊」。
class PeerListTile extends StatelessWidget {
  const PeerListTile({super.key, required this.peer, this.onTap});

  final ChatPeer peer;
  final VoidCallback? onTap;

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
        ChatPeerConnection.unknown => (Icons.help_outline, '連線方式不明'),
      };

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
                      Icon(connectionIcon, size: 13, color: _accent),
                      const SizedBox(width: 4),
                      Text(connectionLabel, style: const TextStyle(fontSize: 12, color: _textSecondary)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (rssi == null)
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
          ],
        ),
      ),
    );
  }
}
