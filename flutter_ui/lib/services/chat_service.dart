import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bitchat_bridge.dart';
import '../models/chat_message.dart';

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
    Future<bool> Function(String text)? sendMessage,
    Future<void> Function(String nickname)? setNickname,
  })  : _events = events ?? BitchatBridge.events,
        _requestSnapshot = requestSnapshot ?? BitchatBridge.requestChatSnapshot,
        _send = sendMessage ?? BitchatBridge.sendMessage,
        _setNickname = setNickname ?? BitchatBridge.setNickname;

  static final ChatService instance = ChatService();

  final Stream<Map<String, dynamic>> Function() _events;
  final Future<void> Function() _requestSnapshot;
  final Future<bool> Function(String text) _send;
  final Future<void> Function(String nickname) _setNickname;

  final ValueNotifier<List<ChatMessage>> _publicMessages =
      ValueNotifier<List<ChatMessage>>(const []);
  final ValueNotifier<String?> _nickname = ValueNotifier<String?>(null);

  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// 公開 mesh 時間線（含本機送出的訊息），依時間線順序；清單不可修改。
  ValueListenable<List<ChatMessage>> get publicMessages => _publicMessages;

  /// 自己的 mesh 暱稱，也就是附近裝置在 announce 裡看到的名稱；原生端還沒回報前是 null。
  ///
  /// 原樣反映原生 `ChatViewModel.nickname`（可能是空字串），任何來源的變更都會經快照更新。
  /// 與帳號的真實姓名（`AppUser.name`）無關，兩者不互相帶入（ADR-0003）。
  ValueListenable<String?> get nickname => _nickname;

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
  /// bridge 錯誤會往上拋，由畫面告知使用者。
  Future<bool> sendMessage(String text) => _send(text);

  /// 把使用者為 mesh 輸入的暱稱原樣交給原生聊天核心（它會儲存並重新 announce）。
  ///
  /// 空白與長度沿用上游規則，這裡不 trim、不擋。[nickname] 不在這裡更新，
  /// 等原生端的快照回推，才會與原生實際持有的值一致。bridge 錯誤會往上拋。
  Future<void> setNickname(String nickname) => _setNickname(nickname);

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
    }
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _publicMessages.dispose();
    _nickname.dispose();
  }
}
