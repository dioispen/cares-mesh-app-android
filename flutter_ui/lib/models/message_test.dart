import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class Message {
  final String messageId;  // UUID v4，管理端追蹤用唯一識別碼
  String sender;
  String text;
  DateTime time;

  Message({
    String? messageId,
    required this.sender,
    required this.text,
    required this.time,
  }) : messageId = messageId ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'sender': sender,
        'text': text,
        'time': time.toIso8601String(),
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        messageId: json['messageId'] as String?,
        sender: json['sender'] as String,
        text: json['text'] as String,
        time: DateTime.parse(json['time'] as String),
      );
}
