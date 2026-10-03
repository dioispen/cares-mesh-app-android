import 'dart:async';
import 'package:flutter/services.dart';

/// 聊天 method 名稱，對應 Kotlin `ChatBridge` 的 companion 常數（命名規則 `chat_<動詞><受詞>`）。
abstract final class ChatMethods {
  static const sendMessage = 'chat_sendMessage';
  static const setNickname = 'chat_setNickname';
  static const getNickname = 'chat_getNickname';
  static const requestSnapshot = 'chat_requestSnapshot';
  static const updateInput = 'chat_updateInput';
  static const selectCommandSuggestion = 'chat_selectCommandSuggestion';
  static const selectMentionSuggestion = 'chat_selectMentionSuggestion';
  static const clearSuggestions = 'chat_clearSuggestions';
  static const startPrivateChat = 'chat_startPrivateChat';
  static const endPrivateChat = 'chat_endPrivateChat';
  static const openLatestUnreadPrivateChat = 'chat_openLatestUnreadPrivateChat';
  static const takePendingNavigation = 'chat_takePendingNavigation';
  static const toggleFavorite = 'chat_toggleFavorite';
}

/// 聊天快照事件的 `type`，對應 Kotlin `ChatSerialization` 的常數（命名規則 `chat_<snake_case>`）。
abstract final class ChatEvents {
  /// `{type, messages: List<Map>}`：公開 mesh 時間線的完整快照，依時間線順序。
  static const publicMessages = 'chat_public_messages';

  /// `{type, nickname: String}`：自己的 mesh 暱稱（原生 `ChatViewModel.nickname`），原樣、可能是空字串。
  static const nickname = 'chat_nickname';

  /// `{type, onlineCount: int, peers: List<Map>}`：線上人數與 mesh peer 列表的完整快照，
  /// 依原生列表的顯示順序：在線 peer，再接離線的我的最愛（`connection: offline`，#58）；每列帶
  /// 我的最愛星號的兩個方向 `isFavorite`、`theyFavoritedUs`（見 `models/chat_peer.dart`）。
  static const peers = 'chat_peers';

  /// `{type, showCommands: bool, commands: List<Map>, showMentions: bool, mentions: List<String>}`：
  /// 輸入框 `/` 指令與 `@` 提及補完的完整快照（原生 `ChatViewModel` 的補完狀態，見
  /// `models/chat_suggestions.dart`）。
  static const suggestions = 'chat_suggestions';

  /// `{type, peerID: String?, conversationID: String?, displayName: String?, draft: String?,
  /// isFavorite: bool?, theyFavoritedUs: bool?}`：原生「目前選定的私訊對象」
  /// （`ChatViewModel.selectedPrivateChatPeer`）與它標頭的我的最愛星號（#58）；沒有時除 `type` 外
  /// 都是 null。私訊畫面依它開關（見 `models/private_chat.dart`）。
  static const selectedPrivatePeer = 'chat_selected_private_peer';

  /// `{type, chats: {conversationID: List<Map>}}`：原生持有的所有私訊對話，訊息 map 與
  /// [publicMessages] 相同（見 `models/chat_message.dart`）。自己送出的私訊帶 `deliveryStatus`，
  /// 送達、已讀或失敗時隨快照更新。被 `/block` 的對象傳來的訊息不在裡面（[publicMessages] 也是，#58）。
  static const privateChats = 'chat_private_chats';

  /// `{type, hasUnread: bool, conversations: {conversationID: int}}`：原生是否有未讀私訊（原生標頭的
  /// 未讀信封），以及每個有未讀的對話的未讀數（見 `models/chat_unread.dart`）。在線 peer 的未讀數也
  /// 在 [peers] 的列上。
  static const unread = 'chat_unread';

  /// `{type, navigation: Map?}`：使用者點了聊天通知、Dart 還沒處理的目的地（#57），沒有時
  /// `navigation` 為 null（見 `models/chat_navigation.dart`）。它只是提醒：要導航前一定先以
  /// [ChatMethods.takePendingNavigation] 取走，照取到的去，每個點擊只處理一次。
  static const pendingNavigation = 'chat_pending_navigation';
}

class BitchatBridge {
  static const MethodChannel _method = MethodChannel('com.bitchat/bridge/methods');
  static const EventChannel _events = EventChannel('com.bitchat/bridge/events');

  // Cached broadcast stream — receiveBroadcastStream() must only be called once
  // per EventChannel; a second call creates a conflicting platform listener.
  static Stream<Map<String, dynamic>>? _cachedEventStream;

  static Stream<Map<String, dynamic>> events() {
    return _cachedEventStream ??= _events
        .receiveBroadcastStream()
        .map((dynamic e) {
          if (e is Map) {
            return e.map((k, v) => MapEntry(k.toString(), v));
          }
          return <String, dynamic>{'type': 'unknown', 'raw': e};
        })
        .asBroadcastStream();
  }

  /// 獲取當前系統狀態 (藍牙、位置、權限)
  static Future<Map<String, dynamic>?> getSystemStatus() async {
    try {
      final Map<dynamic, dynamic>? result = await _method.invokeMethod<Map>('getSystemStatus');
      return result?.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      return null;
    }
  }

  /// 檢查權限是否已開啟 (通知、藍牙、位置)
  static Future<bool> checkPermissions() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('checkPermissions');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 請求權限
  static Future<bool> requestPermissions() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('requestPermissions');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 檢查是否已註冊
  static Future<bool> isRegistered() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('isRegistered');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 啟動 Mesh 服務
  static Future<bool> startMesh() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('startMesh');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 把使用者輸入的文字交給原生聊天核心（`ChatViewModel.sendMessage`）。
  ///
  /// 送往哪裡（公開 mesh、目前開啟的私訊、`/` 指令）由原生核心依它自己的「目前選定的私訊對象」
  /// 決定，Dart 端沒有 peerId／isPublic 之類指定收件者的參數（#9）。
  ///
  /// [privateChat] 只標明文字是在哪個輸入框打的：公開聊天室為 null，私訊畫面為
  /// [ChatEvents.selectedPrivatePeer] 的 `peerID`。原生端只在它的選定對象與此相同時才送出，
  /// 否則回傳 false（沒送出），避免公開訊息被送成私訊、或私訊被公開廣播。空白文字不會送出。
  /// 回傳原生核心是否接受；bridge 錯誤（例如 [PlatformException]）會往上拋。
  static Future<bool> sendMessage(String text, {String? privateChat}) async {
    final bool? accepted = await _method.invokeMethod<bool>(
      ChatMethods.sendMessage,
      <String, dynamic>{'text': text, 'privateChat': privateChat},
    );
    return accepted ?? false;
  }

  /// 開啟私訊（原生 `ChatViewModel.startPrivateChat`：載入儲存的紀錄、設為選定對象、清未讀、
  /// 送已讀回條、必要時開始 Noise 交握）。[peerID] 是 peer 列表的 peer ID 或對話 ID；原生可能改用
  /// 正規化後的對話 ID，也可能拒絕（例如已封鎖）。完成後回傳當下的 [ChatEvents.selectedPrivatePeer]
  /// map。bridge 錯誤會往上拋。
  static Future<Map<dynamic, dynamic>?> startPrivateChat(String peerID) =>
      _method.invokeMethod<Map>(ChatMethods.startPrivateChat, <String, dynamic>{'peerID': peerID});

  /// 結束私訊焦點（原生 `ChatViewModel.endPrivateChat`），之後輸入的文字回到公開聊天室。
  /// 回傳當下的 [ChatEvents.selectedPrivatePeer] map（`peerID` 為 null）。bridge 錯誤會往上拋。
  static Future<Map<dynamic, dynamic>?> endPrivateChat() =>
      _method.invokeMethod<Map>(ChatMethods.endPrivateChat);

  /// 原生標頭未讀信封的動作（原生 `ChatViewModel.openLatestUnreadPrivateChat`）：原生挑出最新收到
  /// 未讀私訊的對話，回傳要開啟的對話 ID；沒有未讀時回傳 null。只挑、不開啟：拿到 ID 後照一般流程
  /// 開私訊畫面（[startPrivateChat]）。bridge 錯誤會往上拋。
  static Future<String?> openLatestUnreadPrivateChat() =>
      _method.invokeMethod<String>(ChatMethods.openLatestUnreadPrivateChat);

  /// 取走使用者點聊天通知要去的地方（#57）：`{target: privateChat, peerID, senderNickname}` 或
  /// `{target: publicChat}`；沒有（或已被取走）時回傳 null。取走後原生不再持有它。只取、不開啟：
  /// 私訊畫面照一般流程呼叫 [startPrivateChat]。bridge 錯誤會往上拋。
  static Future<Map<dynamic, dynamic>?> takePendingChatNavigation() =>
      _method.invokeMethod<Map>(ChatMethods.takePendingNavigation);

  /// 切換我的最愛（原生 `ChatViewModel.toggleFavorite`，原生私訊標頭星號做的事）：加入或移出，
  /// 記下對方的 Noise 公鑰與暱稱（離線後仍找得到），對方在 mesh 上時通知他。[peerID] 原樣傳過去：
  /// peer 列表那一列的 `peerID`（在線是 mesh peer ID，離線的最愛是 Noise 公鑰），或私訊畫面的
  /// [ChatEvents.selectedPrivatePeer] `peerID`。新的星號經 [ChatEvents.peers]、
  /// [ChatEvents.selectedPrivatePeer] 快照回推。bridge 錯誤會往上拋。
  static Future<void> toggleFavorite(String peerID) async {
    await _method.invokeMethod<void>(ChatMethods.toggleFavorite, <String, dynamic>{'peerID': peerID});
  }

  /// 設定 mesh 暱稱（原生 `ChatViewModel.setNickname`：儲存後立即重新 announce）。
  ///
  /// 暱稱會隨 announce 明文廣播給範圍內所有裝置，只能傳使用者親自為 mesh 輸入的名稱，
  /// 絕不能傳帳號的真實姓名（`AppUser.name`，ADR-0003）。文字原樣傳過去：空白與長度的
  /// 處理沿用上游，這裡不另訂規則。新值經 [ChatEvents.nickname] 快照回推；
  /// bridge 錯誤（例如 [MissingPluginException]、[PlatformException]）會往上拋。
  static Future<void> setNickname(String nickname) async {
    await _method.invokeMethod<void>(
      ChatMethods.setNickname,
      <String, dynamic>{'nickname': nickname},
    );
  }

  /// 一次性讀取目前的 mesh 暱稱。畫面請改看 `ChatService.nickname`（[ChatEvents.nickname] 快照），
  /// 它會跟著任何來源的變更更新。bridge 錯誤會往上拋。
  static Future<String> getNickname() async {
    final String? nickname = await _method.invokeMethod<String>(ChatMethods.getNickname);
    if (nickname == null) {
      throw PlatformException(code: 'NO_NICKNAME', message: '${ChatMethods.getNickname} answered null');
    }
    return nickname;
  }

  /// 請原生端立刻重推所有 `chat_*` 快照事件（經事件串流送達，不是回傳值）。
  ///
  /// 事件串流是共用的 broadcast stream，原生端只在「第一個」Dart listener 訂閱時推快照；
  /// 較晚訂閱的 `ChatService` 用這個補拿目前狀態。
  static Future<void> requestChatSnapshot() async {
    await _method.invokeMethod<void>(ChatMethods.requestSnapshot);
  }

  /// 輸入框文字改變時呼叫（原生輸入框在每次文字變化時做的事）。[privateChat] 同 [sendMessage]：
  /// 公開聊天室（null）的文字用來更新 `/` 指令與 `@` 提及補完，結果經 [ChatEvents.suggestions]
  /// 快照回推；私訊輸入框的文字只存成該私訊的草稿（原生私訊畫面沒有補完）。文字原樣傳過去。
  /// bridge 錯誤會往上拋。
  static Future<void> updateChatInput(String text, {String? privateChat}) async {
    await _method.invokeMethod<void>(
      ChatMethods.updateInput,
      <String, dynamic>{'text': text, 'privateChat': privateChat},
    );
  }

  /// 選取一個 `/` 指令補完，回傳輸入框的新文字（原生 `selectCommandSuggestion`，同時關閉清單）。
  ///
  /// 只傳指令名稱，原生端從它目前提供的清單找回上游物件；該指令已不在清單上時回傳 null，
  /// 輸入框不要變。bridge 錯誤會往上拋。
  static Future<String?> selectCommandSuggestion(String command) =>
      _method.invokeMethod<String>(ChatMethods.selectCommandSuggestion, <String, dynamic>{'command': command});

  /// 選取一個 `@` 提及補完，回傳輸入框的新文字（原生 `selectMentionSuggestion`：把正在輸入的
  /// `@片段` 換成 `@暱稱 `，同時關閉清單）。[currentText] 是選取當下輸入框的文字。
  /// bridge 錯誤會往上拋。
  static Future<String> selectMentionSuggestion(String nickname, String currentText) async {
    final String? text = await _method.invokeMethod<String>(
      ChatMethods.selectMentionSuggestion,
      <String, dynamic>{'nickname': nickname, 'currentText': currentText},
    );
    if (text == null) {
      throw PlatformException(code: 'NO_TEXT', message: '${ChatMethods.selectMentionSuggestion} answered null');
    }
    return text;
  }

  /// 關閉兩個補完清單（原生輸入框在送出、清空文字後這樣做）。bridge 錯誤會往上拋。
  static Future<void> clearChatSuggestions() async {
    await _method.invokeMethod<void>(ChatMethods.clearSuggestions);
  }

  /// 發送 Health Report 的 Broadcast Tier（BLE 廣播 + 網路回報）。
  ///
  /// 傳入的 map 只應含不具識別性的欄位：`reporterHandle`、`status`（中文 label）、
  /// 以及原始 `lat`/`lng`（由原生端就地降精度為 geohash）。姓名、電話、血型、自由文字
  /// 等 Detail Tier 欄位不要放進來——原生端也會忽略（見 ADR-0003）。
  static Future<void> sendHealthReport(Map<String, dynamic> broadcastTier) async {
    try {
      await _method.invokeMethod<void>('sendHealthReport', broadcastTier);
    } catch (e) {
      // Ignore
    }
  }
}
