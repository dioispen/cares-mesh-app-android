import 'package:flutter/material.dart';

import '../models/chat_message.dart';

/// 聊天室的配色（公開聊天室、私訊畫面、輸入區共用）。
abstract final class ChatPalette {
  static const bg = Color(0xFFF7F3EC);
  static const card = Color(0xFFFEFDF9);
  static const textPrimary = Color(0xFF3D2C1E);
  static const textSecondary = Color(0xFF8C7B6E);
  static const accent = Color(0xFF9B88B3);
  static const accentDark = Color(0xFF6F5A8C);
  static const divider = Color(0xFFE8E0D5);

  /// 提到我的訊息與 `@我` 的醒目色（原生用強調橘色標示指到自己的提及）。
  static const mention = Color(0xFFC96F1E);
  static const mentionBg = Color(0xFFFFF3E3);

  /// 未讀私訊的標示色（原生的強調橘色：標頭的未讀信封、對話列的數字徽章）。
  static const unread = mention;

  /// 送達標記的三種顏色，對照原生 `MessageComponents.kt` 的 `deliveryCheckColors`：
  /// 還沒有回條時灰色（原生 `onSurface` 35%）、送達／已讀用主色綠、失敗用錯誤紅。
  static const deliveryPending = Color(0x593D2C1E);
  static const deliveryAcknowledged = Color(0xFF2E7D32);
  static const deliveryFailed = Color(0xFFC62828);

  static const _avatarColors = [
    Color(0xFF6B9EAD),
    Color(0xFF7AA67A),
    Color(0xFFBF7A5A),
    Color(0xFF9B88B3),
  ];

  /// 依名稱固定的頭像顏色（peer 列表用同一組顏色與規則）。
  static Color avatarColor(String name) => _avatarColors[name.hashCode.abs() % _avatarColors.length];
}

/// 時間線上的一則訊息：系統訊息置中顯示；其餘是氣泡，自己的在右、別人的在左並附頭像與名稱。
///
/// 誰是自己、哪些是系統訊息、誰被 @ 到都照原生算好的欄位（[ChatMessage.isFromSelf]、
/// [ChatMessage.isSystem]、[ChatMessage.mentionsMe]、[ChatMessage.mentionSpans]），這裡不重新判斷。
///
/// 自己送出的私訊在時間後面接送達標記（[DeliveryStatusMark]），與原生相同；公開訊息沒有。
class ChatMessageTile extends StatelessWidget {
  const ChatMessageTile({super.key, required this.message});

  final ChatMessage message;

  static String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _initialOf(String sender) => sender.characters.isEmpty ? '?' : sender.characters.first;

  @override
  Widget build(BuildContext context) {
    final msg = message;
    final isMe = msg.isFromSelf;

    if (msg.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: ChatPalette.divider.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            msg.content,
            style: const TextStyle(fontSize: 12, color: ChatPalette.textSecondary),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: ChatPalette.avatarColor(msg.sender),
              child: Text(
                _initialOf(msg.sender),
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(msg.sender, style: const TextStyle(fontSize: 11, color: ChatPalette.textSecondary)),
                      if (msg.mentionsMe) ...[const SizedBox(width: 6), const _MentionMark()],
                    ],
                  ),
                ),
              Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isMe ? ChatPalette.accent : (msg.mentionsMe ? ChatPalette.mentionBg : ChatPalette.card),
                  border: msg.mentionsMe
                      ? Border.all(color: ChatPalette.mention.withValues(alpha: 0.55), width: 1.2)
                      : null,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(isMe ? 18 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 18),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: ChatPalette.textPrimary.withValues(alpha: 0.06),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: _messageText(msg, isMe),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(msg.timestamp),
                      style: const TextStyle(fontSize: 10, color: ChatPalette.textSecondary),
                    ),
                    if (_deliveryStatusOf(msg) case final status?) ...[
                      const SizedBox(width: 4),
                      DeliveryStatusMark(status: status),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 要畫送達標記的狀態：原生只為自己送出的私訊畫（`message.isPrivate && sender == 我`），
  /// 沒有狀態、或是這個版本不認得的狀態時不畫。
  static DeliveryStatus? _deliveryStatusOf(ChatMessage msg) {
    final status = msg.deliveryStatus;
    if (!msg.isPrivate || !msg.isFromSelf || status == null || status is DeliveryUnknown) return null;
    return status;
  }

  /// 訊息文字。`@暱稱` 以 chip 樣式強調、指到我的最醒目，與原生相同；位置由 Kotlin 給
  /// （[ChatMessage.mentionSpans]），這裡不自己找 `@`。
  static Widget _messageText(ChatMessage msg, bool isMe) {
    final style = TextStyle(fontSize: 14, color: isMe ? Colors.white : ChatPalette.textPrimary, height: 1.45);
    if (msg.mentionSpans.isEmpty) return Text(msg.content, style: style);
    final content = msg.content;
    final children = <TextSpan>[];
    var cursor = 0;
    for (final span in msg.mentionSpans) {
      if (span.start > cursor) children.add(TextSpan(text: content.substring(cursor, span.start)));
      children.add(TextSpan(
        text: content.substring(span.start, span.end),
        style: _mentionStyle(isMine: span.isMe, onOwnBubble: isMe),
      ));
      cursor = span.end;
    }
    if (cursor < content.length) children.add(TextSpan(text: content.substring(cursor)));
    return Text.rich(TextSpan(children: children), style: style);
  }

  static TextStyle _mentionStyle({required bool isMine, required bool onOwnBubble}) {
    final weight = isMine ? FontWeight.w700 : FontWeight.w600;
    if (onOwnBubble) {
      // 自己的紫色氣泡上維持白字，以粗細與底色區分。
      return TextStyle(fontWeight: weight, backgroundColor: Colors.white.withValues(alpha: isMine ? 0.28 : 0.16));
    }
    final color = isMine ? ChatPalette.mention : ChatPalette.accentDark;
    return TextStyle(fontWeight: weight, color: color, backgroundColor: color.withValues(alpha: 0.14));
  }
}

/// 「提及你」標記，放在提到我的訊息的送出者名稱旁。
class _MentionMark extends StatelessWidget {
  const _MentionMark();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: ChatPalette.mention.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alternate_email, size: 11, color: ChatPalette.mention),
            SizedBox(width: 2),
            Text('提及你', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: ChatPalette.mention)),
          ],
        ),
      );
}

/// 自己送出的私訊的送達標記，對照原生 `MessageComponents.kt` 的 `DeliveryStatusIcon`：永遠是兩個
/// `✓`（狀態變化只換顏色、不改版面），依原生 `deliveryCheckColors` 上色——
/// 傳送中／已送出兩個灰、已送達（含部分送達）第一個綠、已讀兩個綠、失敗兩個紅。
///
/// 原生只畫符號；這裡另以 tooltip（也是無障礙標籤）說明狀態，文字對照原生
/// `DeliveryStatus.getDisplayText()`（失敗時附上原生給的原因）。
class DeliveryStatusMark extends StatelessWidget {
  const DeliveryStatusMark({super.key, required this.status});

  final DeliveryStatus status;

  /// 狀態說明；[DeliveryUnknown] 沒有（不畫標記）。
  static String? labelOf(DeliveryStatus status) => switch (status) {
        DeliverySending() => '傳送中…',
        DeliverySent() => '已送出',
        DeliveryDelivered() => '已送達',
        DeliveryRead() => '已讀',
        DeliveryFailed(:final reason) => reason.isEmpty ? '傳送失敗' : '傳送失敗：$reason',
        DeliveryPartiallyDelivered(:final reached, :final total) => '已送達 $reached/$total',
        DeliveryUnknown() => null,
      };

  /// 兩個 `✓` 各自的顏色（原生 `deliveryCheckColors`）。
  static (Color, Color) colorsOf(DeliveryStatus status) => switch (status) {
        DeliveryRead() => (ChatPalette.deliveryAcknowledged, ChatPalette.deliveryAcknowledged),
        DeliveryDelivered() || DeliveryPartiallyDelivered() => (
            ChatPalette.deliveryAcknowledged,
            ChatPalette.deliveryPending,
          ),
        DeliveryFailed() => (ChatPalette.deliveryFailed, ChatPalette.deliveryFailed),
        _ => (ChatPalette.deliveryPending, ChatPalette.deliveryPending),
      };

  @override
  Widget build(BuildContext context) {
    final label = labelOf(status);
    if (label == null) return const SizedBox.shrink();
    final (first, second) = colorsOf(status);
    return Tooltip(
      message: label,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '✓', style: TextStyle(color: first)),
          TextSpan(text: '✓', style: TextStyle(color: second)),
        ]),
        style: const TextStyle(fontSize: 10),
      ),
    );
  }
}
