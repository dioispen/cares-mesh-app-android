import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class BroadcastMessage {
  final String messageId;  // UUID v4，管理端追蹤用唯一識別碼
  final String senderId;   // 發送者 ID（哪位市民送出）
  final String content;    // 訊息內容（例如 "Hello World"）
  final DateTime sentAt;   // 發送時間
  final String type;       // 訊息類型（test / sos / report）

  BroadcastMessage({
    String? messageId,
    required this.senderId,
    required this.content,
    required this.sentAt,
    required this.type,
  }) : messageId = messageId ?? _uuid.v4();

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'senderId': senderId,
      'content': content,
      'sentAt': sentAt.toIso8601String(),
      'type': type,
    };
  }

  factory BroadcastMessage.fromMap(Map<String, dynamic> map) {
    return BroadcastMessage(
      messageId: map['messageId'] as String?,
      senderId: map['senderId'] as String,
      content: map['content'] as String,
      sentAt: DateTime.parse(map['sentAt'] as String),
      type: map['type'] as String,
    );
  }

  factory BroadcastMessage.helloWorld({required String senderId}) {
    return BroadcastMessage(
      senderId: senderId,
      content: 'Hello World',
      sentAt: DateTime.now(),
      type: 'test',
    );
  }
}
