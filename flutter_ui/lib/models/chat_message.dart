/// 聊天訊息的 Dart 端模型（#49）。
///
/// 欄位與 Kotlin `ChatSerialization.message`
/// （`app/src/main/java/com/bitchat/android/flutter/ChatSerialization.kt`）一一對應，兩邊要一起改。
/// 聊天規則（誰是自己、哪些是系統訊息、送達狀態怎麼變、誰被 @ 到）都由原生 `ChatViewModel`
/// 與 Kotlin 投影層決定，這裡只負責把 bridge 推來的 map 轉成型別，不重新推導。
///
/// 解析一律容錯：缺欄位或型別不符時用預設值，未知的送達狀態 `kind` 變成 [DeliveryUnknown]，
/// 永遠不丟例外——bridge 的資料不該讓聊天室崩潰。
library;

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

String _string(Object? v) => v is String ? v : '';

String? _nullableString(Object? v) => v is String ? v : null;

bool _bool(Object? v) => v is bool ? v : false;

int _int(Object? v) => v is int ? v : 0;

DateTime _millis(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : _epoch;

List<String> _strings(Object? v) =>
    v is List ? List.unmodifiable(v.whereType<String>()) : const <String>[];

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.sender,
    this.senderPeerID,
    required this.content,
    required this.timestamp,
    this.isPrivate = false,
    this.mentions = const [],
    this.isRelay = false,
    this.deliveryStatus,
    this.isFromSelf = false,
    this.isSystem = false,
    this.mentionsMe = false,
    this.mentionSpans = const [],
  });

  final String id;

  /// 送出者的 mesh 暱稱（上游可能加上 `#xxxx` 以區分同名者）。
  final String sender;
  final String? senderPeerID;
  final String content;

  /// 缺值時為 epoch 0。
  final DateTime timestamp;
  final bool isPrivate;
  final List<String> mentions;
  final bool isRelay;

  /// 只有自己送出的私訊才有；公開訊息為 null。
  final DeliveryStatus? deliveryStatus;

  /// 依上游 UI 的規則判斷為本機送出（右側氣泡）。
  final bool isFromSelf;

  /// 上游自己產生的通知（例如指令結果），以系統訊息樣式顯示。
  final bool isSystem;

  /// 別人傳來、內容 @ 到我目前暱稱的訊息，要醒目標示。規則在 Kotlin `ChatMentions`
  /// （照原生聊天室的提及 chip：`@暱稱` 或 `@暱稱#abcd`，大小寫須相同；自己的訊息不算）。
  final bool mentionsMe;

  /// [content] 中每個 `@暱稱` token 的位置（UTF-16 索引，與 Dart 字串相同），依序、不重疊、
  /// 都在 [content] 範圍內；系統訊息沒有。不可修改。
  final List<MentionSpan> mentionSpans;

  /// 不是 Map 時回傳 null；其餘情況一定回傳訊息。
  static ChatMessage? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return ChatMessage(
      id: _string(raw['id']),
      sender: _string(raw['sender']),
      senderPeerID: _nullableString(raw['senderPeerID']),
      content: _string(raw['content']),
      timestamp: _millis(raw['timestamp']),
      isPrivate: _bool(raw['isPrivate']),
      mentions: _strings(raw['mentions']),
      isRelay: _bool(raw['isRelay']),
      deliveryStatus: DeliveryStatus.fromMap(raw['deliveryStatus']),
      isFromSelf: _bool(raw['isFromSelf']),
      isSystem: _bool(raw['isSystem']),
      mentionsMe: _bool(raw['mentionsMe']),
      mentionSpans: MentionSpan.listFrom(raw['mentionSpans'], _string(raw['content'])),
    );
  }

  /// 解析一份訊息清單（保留順序、略過不是 Map 的項目）。
  /// 不是 List 時回傳 null，讓呼叫端保留現有狀態，而不是把畫面清空。
  static List<ChatMessage>? listFrom(Object? raw) {
    if (raw is! List) return null;
    return [
      for (final entry in raw) ?ChatMessage.fromMap(entry),
    ];
  }
}

/// 訊息內容中的一個 `@暱稱` token：`content.substring(start, end)`。
class MentionSpan {
  const MentionSpan({required this.start, required this.end, this.isMe = false});

  final int start;
  final int end;

  /// 這個 token 指的是我目前的暱稱（原生以最醒目的樣式顯示）。
  final bool isMe;

  /// 只保留能套在 [content] 上的 span：`0 <= start < end <= content.length`，且不與前一個重疊；
  /// 其餘略過。不是 List 時回傳空清單。
  static List<MentionSpan> listFrom(Object? raw, String content) {
    if (raw is! List) return const [];
    final spans = <MentionSpan>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final start = entry['start'];
      final end = entry['end'];
      if (start is! int || end is! int) continue;
      final previousEnd = spans.isEmpty ? 0 : spans.last.end;
      if (start < previousEnd || end <= start || end > content.length) continue;
      spans.add(MentionSpan(start: start, end: end, isMe: _bool(entry['isMe'])));
    }
    return List.unmodifiable(spans);
  }
}

/// 對應 Kotlin `DeliveryStatus`，以 `kind` 區分子型別。
sealed class DeliveryStatus {
  const DeliveryStatus();

  /// null 或不是 Map 時回傳 null（沒有狀態）；未知或缺少的 `kind` 回傳 [DeliveryUnknown]。
  static DeliveryStatus? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final kind = _string(raw['kind']);
    return switch (kind) {
      'sending' => const DeliverySending(),
      'sent' => const DeliverySent(),
      'delivered' => DeliveryDelivered(to: _string(raw['to']), at: _millis(raw['at'])),
      'read' => DeliveryRead(by: _string(raw['by']), at: _millis(raw['at'])),
      'failed' => DeliveryFailed(reason: _string(raw['reason'])),
      'partiallyDelivered' =>
        DeliveryPartiallyDelivered(reached: _int(raw['reached']), total: _int(raw['total'])),
      _ => DeliveryUnknown(kind),
    };
  }
}

final class DeliverySending extends DeliveryStatus {
  const DeliverySending();
}

final class DeliverySent extends DeliveryStatus {
  const DeliverySent();
}

final class DeliveryDelivered extends DeliveryStatus {
  const DeliveryDelivered({required this.to, required this.at});

  final String to;
  final DateTime at;
}

final class DeliveryRead extends DeliveryStatus {
  const DeliveryRead({required this.by, required this.at});

  final String by;
  final DateTime at;
}

final class DeliveryFailed extends DeliveryStatus {
  const DeliveryFailed({required this.reason});

  final String reason;
}

final class DeliveryPartiallyDelivered extends DeliveryStatus {
  const DeliveryPartiallyDelivered({required this.reached, required this.total});

  final int reached;
  final int total;
}

/// 比這個版本新的原生端送來的狀態；保留 `kind` 以便除錯，UI 可以忽略。
final class DeliveryUnknown extends DeliveryStatus {
  const DeliveryUnknown(this.kind);

  final String kind;
}
