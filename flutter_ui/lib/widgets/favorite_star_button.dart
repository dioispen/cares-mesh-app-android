import 'package:flutter/material.dart';

import 'chat_message_tile.dart' show ChatPalette;

/// 我的最愛星號（#58），對照原生私訊標頭的星號（`MeshPeerListSheet.kt` 的 `PrivateChatSheet`：
/// `favoriteStarTint`、`ic_spec_star_filled`／`ic_spec_star`）與 peer 列表頭像上的星號（`PeerAvatar`）：
/// - 實心橘色：我把對方加入了最愛（不論對方有沒有加我）。
/// - 橘色空心：對方把我加入了最愛，我還沒有加他。
/// - 灰色空心：彼此都沒有。
///
/// 兩個狀態都照原生投影來的值（[isFavorite]、[theyFavoritedUs]）顯示；按下只呼叫 [onPressed]，
/// 這裡不先改樣子，等原生的快照回推。
class FavoriteStarButton extends StatelessWidget {
  const FavoriteStarButton({
    super.key,
    required this.isFavorite,
    required this.theyFavoritedUs,
    required this.onPressed,
    this.size = 22,
  });

  final bool isFavorite;
  final bool theyFavoritedUs;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final orange = isFavorite || theyFavoritedUs;
    return Semantics(
      // 原生的無障礙說明：`cd_favorite`「Favorite」、`cd_favorited_you`「Favorited you」。
      label: [
        if (isFavorite) '我的最愛',
        if (theyFavoritedUs) '對方已將你加入最愛',
      ].join('，'),
      child: IconButton(
        // 原生 `cd_remove_favorite`／`cd_add_favorite` 的 zh-TW 字串。
        tooltip: isFavorite ? '從最愛移除' : '加入最愛',
        onPressed: onPressed,
        icon: Icon(
          isFavorite ? Icons.star : Icons.star_border,
          size: size,
          color: orange ? ChatPalette.favorite : ChatPalette.textSecondary,
        ),
      ),
    );
  }
}
