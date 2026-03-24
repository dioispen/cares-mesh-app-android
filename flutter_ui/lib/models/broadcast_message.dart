class BroadcastMessage {
  final String senderId;   // 發送者 ID（哪位市民送出）
  final String content;    // 訊息內容（例如 "Hello World"）
  final DateTime sentAt;   // 發送時間
  final String type;       // 訊息類型（test / sos / report）

  BroadcastMessage({
    required this.senderId,
    required this.content,
    required this.sentAt,
    required this.type,
  });

  // 轉成 Map，方便通訊組打包後傳送到管理端
  Map<String, dynamic> toMap() {
    return {
      'senderId': senderId,
      'content': content,
      'sentAt': sentAt.toIso8601String(),
      'type': type,
    };
  }

  // 建立一筆「Hello World」測試訊息的工廠方法
  factory BroadcastMessage.helloWorld({required String senderId}) {
    return BroadcastMessage(
      senderId: senderId,
      content: 'Hello World',
      sentAt: DateTime.now(),
      type: 'test',
    );
  }
}
