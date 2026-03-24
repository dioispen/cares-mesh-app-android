class Message {
  String sender;
  String text;
  DateTime time;

  Message(this.sender, this.text, this.time);

  Map<String, dynamic> toJson() => {
        'sender': sender,
        'text': text,
        'time': time.toIso8601String(),
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        json['sender'] as String,
        json['text'] as String,
        DateTime.parse(json['time'] as String),
      );
}