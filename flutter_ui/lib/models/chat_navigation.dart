/// 點通知後要前往的聊天畫面（#57）的 Dart 端模型。
///
/// 欄位與 Kotlin `ChatSerialization.navigation`（`app/src/main/java/com/bitchat/android/flutter/
/// ChatSerialization.kt`、`ChatNavigation.kt`）一一對應，兩邊要一起改。要去哪裡由原生讀上游通知的
/// intent extras 決定；這裡只把 map 轉成型別。
///
/// 解析一律容錯、永遠不丟例外：格式不對、或這個 app 不認得的目的地，都當作「哪裡都不去」（null）。
library;

/// 一個通知點擊的目的地：[OpenPrivateChat] 或 [OpenPublicChat]。
sealed class ChatNavigation {
  const ChatNavigation();

  /// 解析 `{target: privateChat, peerID, senderNickname}` 或 `{target: publicChat}`；
  /// null、格式不對或未知的 `target` 回傳 null。
  static ChatNavigation? fromMap(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['target']) {
      case 'privateChat':
        final peerID = raw['peerID'];
        if (peerID is! String || peerID.isEmpty) return null;
        final nickname = raw['senderNickname'];
        return OpenPrivateChat(peerID, senderNickname: nickname is String ? nickname : null);
      case 'publicChat':
        return const OpenPublicChat();
    }
    return null;
  }
}

/// 私訊通知：開啟與 [peerID]（原生的對話 ID）的私訊畫面。
final class OpenPrivateChat extends ChatNavigation {
  const OpenPrivateChat(this.peerID, {this.senderNickname});

  final String peerID;

  /// 通知上顯示的寄件者名稱（上游 intent 原樣帶來）；畫面標題仍以原生的選定私訊為準。
  final String? senderNickname;

  @override
  String toString() => 'OpenPrivateChat($peerID)';
}

/// mesh @提及通知：回到公開聊天室。
final class OpenPublicChat extends ChatNavigation {
  const OpenPublicChat();

  @override
  String toString() => 'OpenPublicChat()';
}
