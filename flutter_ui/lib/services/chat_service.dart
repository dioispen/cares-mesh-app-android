import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bitchat_bridge.dart';
import '../models/chat_message.dart';
import '../models/chat_peer.dart';
import '../models/chat_suggestions.dart';
import '../models/private_chat.dart';

/// Flutter 端的聊天狀態持有者（#49），整個 app 生命週期只有一個：[ChatService.instance]。
///
/// 聊天的真相來源是原生 `ChatViewModel`；這裡只保存 bridge 推來的最新快照，
/// 並把使用者動作轉交給 bridge。app 一啟動就 [start]（見 `main.dart`），
/// 所以不在聊天室畫面時收到的訊息，回到聊天室時也看得到。
///
/// 快照一律整份取代，不在 Dart 合併或推導狀態。Activity 重建會讓 Dart 狀態歸零，
/// [start] 會向原生端要求重推快照來還原。
class ChatService {
  /// 參數只給測試注入；正式環境用 [ChatService.instance]。
  ChatService({
    Stream<Map<String, dynamic>> Function()? events,
    Future<void> Function()? requestSnapshot,
    Future<bool> Function(String text, String? privateChat)? sendMessage,
    Future<void> Function(String nickname)? setNickname,
    Future<void> Function(String text, String? privateChat)? updateInput,
    Future<String?> Function(String command)? selectCommandSuggestion,
    Future<String> Function(String nickname, String currentText)? selectMentionSuggestion,
    Future<void> Function()? clearSuggestions,
    Future<Object?> Function(String peerID)? startPrivateChat,
    Future<Object?> Function()? endPrivateChat,
  })  : _events = events ?? BitchatBridge.events,
        _requestSnapshot = requestSnapshot ?? BitchatBridge.requestChatSnapshot,
        _send = sendMessage ?? ((text, privateChat) => BitchatBridge.sendMessage(text, privateChat: privateChat)),
        _setNickname = setNickname ?? BitchatBridge.setNickname,
        _updateInput =
            updateInput ?? ((text, privateChat) => BitchatBridge.updateChatInput(text, privateChat: privateChat)),
        _selectCommand = selectCommandSuggestion ?? BitchatBridge.selectCommandSuggestion,
        _selectMention = selectMentionSuggestion ?? BitchatBridge.selectMentionSuggestion,
        _clearSuggestions = clearSuggestions ?? BitchatBridge.clearChatSuggestions,
        _startPrivateChat = startPrivateChat ?? BitchatBridge.startPrivateChat,
        _endPrivateChat = endPrivateChat ?? BitchatBridge.endPrivateChat;

  static final ChatService instance = ChatService();

  final Stream<Map<String, dynamic>> Function() _events;
  final Future<void> Function() _requestSnapshot;
  final Future<bool> Function(String text, String? privateChat) _send;
  final Future<void> Function(String nickname) _setNickname;
  final Future<void> Function(String text, String? privateChat) _updateInput;
  final Future<String?> Function(String command) _selectCommand;
  final Future<String> Function(String nickname, String currentText) _selectMention;
  final Future<void> Function() _clearSuggestions;
  final Future<Object?> Function(String peerID) _startPrivateChat;
  final Future<Object?> Function() _endPrivateChat;

  final ValueNotifier<List<ChatMessage>> _publicMessages =
      ValueNotifier<List<ChatMessage>>(const []);
  final ValueNotifier<String?> _nickname = ValueNotifier<String?>(null);
  final ValueNotifier<ChatPeerList?> _peerList = ValueNotifier<ChatPeerList?>(null);
  final ValueNotifier<ChatSuggestions> _suggestions = ValueNotifier<ChatSuggestions>(ChatSuggestions.none);
  final ValueNotifier<PrivateChatFocus?> _selectedPrivateChat = ValueNotifier<PrivateChatFocus?>(null);
  final ValueNotifier<Map<String, List<ChatMessage>>> _privateChats =
      ValueNotifier<Map<String, List<ChatMessage>>>(const {});

  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// 公開 mesh 時間線（含本機送出的訊息），依時間線順序；清單不可修改。
  ValueListenable<List<ChatMessage>> get publicMessages => _publicMessages;

  /// 自己的 mesh 暱稱，也就是附近裝置在 announce 裡看到的名稱；原生端還沒回報前是 null。
  ///
  /// 原樣反映原生 `ChatViewModel.nickname`（可能是空字串），任何來源的變更都會經快照更新。
  /// 與帳號的真實姓名（`AppUser.name`）無關，兩者不互相帶入（ADR-0003）。
  ValueListenable<String?> get nickname => _nickname;

  /// 目前 mesh 上的線上人數與 peer 列表（原生標頭人數與 peer 列表的投影），peer 加入、
  /// 離開、改名或訊號變化時整份更新；原生端還沒回報前是 null。
  ///
  /// 人數與列表放在同一個值裡，一定來自同一份快照。
  ValueListenable<ChatPeerList?> get peerList => _peerList;

  /// 輸入框上方的 `/` 指令與 `@` 提及補完（原生 `ChatViewModel` 補完狀態的投影）；
  /// 原生端還沒回報前是 [ChatSuggestions.none]。只隨快照更新，這裡的方法不會先行改動它。
  ValueListenable<ChatSuggestions> get suggestions => _suggestions;

  /// 原生聊天核心目前選定的私訊（`ChatViewModel.selectedPrivateChatPeer` 的投影）；null 表示沒有，
  /// 輸入的文字會送到公開聊天室。私訊畫面只依它開關，不自行判斷。
  ///
  /// 除了快照，[startPrivateChat]／[endPrivateChat] 完成時也會以原生回傳的當下值更新它
  /// （原生確認過的狀態，不是樂觀猜測），讓畫面不必等下一份快照。
  ValueListenable<PrivateChatFocus?> get selectedPrivateChat => _selectedPrivateChat;

  /// 原生持有的所有私訊對話（對話鍵 → 訊息），整份隨快照更新；不可修改。
  /// 某個對話的訊息用 [PrivateChatFocus.messagesIn] 取。
  ValueListenable<Map<String, List<ChatMessage>>> get privateChats => _privateChats;

  /// 開始接收聊天快照。可重複呼叫，只有第一次有效。
  ///
  /// 先訂閱事件，再請原生端重推快照：事件串流是共用的 broadcast stream，
  /// 若別的畫面先訂閱，原生端的 onListen 早已觸發過，不會為這裡再推一次。
  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = _events().listen(
      _handleEvent,
      onError: (Object error) => debugPrint('ChatService: event stream error: $error'),
    );
    try {
      await _requestSnapshot();
    } catch (e) {
      // 沒有原生端（iOS、測試）或 engine 正在清理；之後的快照事件仍會送達。
      debugPrint('ChatService: snapshot request failed: $e');
    }
  }

  /// 把使用者輸入的文字交給原生聊天核心，回傳是否被接受（接受後才清空輸入框）。
  ///
  /// [privateChat] 標明是哪個輸入框：公開聊天室不傳，私訊畫面傳它的 [PrivateChatFocus.peerID]。
  /// 送往哪裡仍由原生決定；原生的選定對象與 [privateChat] 不同時不送出、回傳 false
  /// （見 `BitchatBridge.sendMessage`）。bridge 錯誤會往上拋，由畫面告知使用者。
  Future<bool> sendMessage(String text, {String? privateChat}) => _send(text, privateChat);

  /// 開啟私訊（原生 `ChatViewModel.startPrivateChat`），完成後以原生回傳的選定私訊更新
  /// [selectedPrivateChat]：原生可能改用正規化的對話 ID，也可能拒絕（例如已封鎖，這時是 null）。
  /// bridge 錯誤會往上拋。
  Future<void> startPrivateChat(String peerID) async => _applySelection(await _startPrivateChat(peerID));

  /// 結束私訊焦點（原生 `ChatViewModel.endPrivateChat`），完成後 [selectedPrivateChat] 為原生回傳的
  /// 值（null）。之後公開聊天室的文字不會被送成私訊。bridge 錯誤會往上拋。
  Future<void> endPrivateChat() async => _applySelection(await _endPrivateChat());

  void _applySelection(Object? raw) {
    final selection = PrivateChatSelection.fromEvent(raw);
    if (selection == null) {
      debugPrint('ChatService: ignoring malformed private chat selection: $raw');
      return;
    }
    _selectedPrivateChat.value = selection.focus;
  }

  /// 把使用者為 mesh 輸入的暱稱原樣交給原生聊天核心（它會儲存並重新 announce）。
  ///
  /// 空白與長度沿用上游規則，這裡不 trim、不擋。[nickname] 不在這裡更新，
  /// 等原生端的快照回推，才會與原生實際持有的值一致。bridge 錯誤會往上拋。
  Future<void> setNickname(String nickname) => _setNickname(nickname);

  /// 輸入框文字改變（使用者輸入）時呼叫，原生核心據此更新補完；私訊輸入框（[privateChat]，
  /// 同 [sendMessage]）的文字也存成該私訊的草稿。文字原樣傳過去；程式設定文字（選取補完、
  /// 送出後清空）時不要呼叫，與原生輸入框相同。bridge 錯誤會往上拋。
  Future<void> updateInput(String text, {String? privateChat}) => _updateInput(text, privateChat);

  /// 選取 [suggestion]，回傳輸入框的新文字；原生端已不再提供它時回傳 null（輸入框不要變）。
  /// 只把 `command` 交回原生端。bridge 錯誤會往上拋。
  Future<String?> selectCommandSuggestion(CommandSuggestion suggestion) => _selectCommand(suggestion.command);

  /// 選取提及 [nickname]，[currentText] 是當下輸入框的文字；回傳輸入框的新文字。
  /// bridge 錯誤會往上拋。
  Future<String> selectMentionSuggestion(String nickname, String currentText) =>
      _selectMention(nickname, currentText);

  /// 關閉補完清單（送出後、或輸入框重新開始時）。bridge 錯誤會往上拋。
  Future<void> clearSuggestions() => _clearSuggestions();

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case ChatEvents.publicMessages:
        final messages = ChatMessage.listFrom(event['messages']);
        if (messages == null) {
          debugPrint('ChatService: ignoring malformed ${ChatEvents.publicMessages} event');
          return;
        }
        _publicMessages.value = List.unmodifiable(messages);
      case ChatEvents.nickname:
        final nickname = event['nickname'];
        if (nickname is! String) {
          debugPrint('ChatService: ignoring malformed ${ChatEvents.nickname} event');
          return;
        }
        _nickname.value = nickname;
      case ChatEvents.peers:
        final peerList = ChatPeerList.fromEvent(event);
        if (peerList == null) {
          debugPrint('ChatService: ignoring malformed ${ChatEvents.peers} event');
          return;
        }
        _peerList.value = peerList;
      case ChatEvents.suggestions:
        final suggestions = ChatSuggestions.fromEvent(event);
        if (suggestions == null) {
          debugPrint('ChatService: ignoring malformed ${ChatEvents.suggestions} event');
          return;
        }
        _suggestions.value = suggestions;
      case ChatEvents.selectedPrivatePeer:
        _applySelection(event);
      case ChatEvents.privateChats:
        final chats = PrivateChats.fromEvent(event);
        if (chats == null) {
          debugPrint('ChatService: ignoring malformed ${ChatEvents.privateChats} event');
          return;
        }
        _privateChats.value = chats;
    }
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _publicMessages.dispose();
    _nickname.dispose();
    _peerList.dispose();
    _suggestions.dispose();
    _selectedPrivateChat.dispose();
    _privateChats.dispose();
  }
}
