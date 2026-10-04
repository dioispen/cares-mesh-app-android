import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_navigation.dart';
import '../screens/chat_screen.dart';
import '../screens/private_chat_screen.dart';
import '../services/chat_service.dart';

/// 把點了的聊天通知帶到正確的畫面（#57）。放在登入後的首頁（`HomeScreen`）裡，包住它的內容。
///
/// 原生收到通知點擊後只記下目的地（[ChatService.pendingNavigation]），由這裡在「可以導航」時取走
/// （[ChatService.takePendingNavigation]，每個點擊只處理一次）：這個 widget 掛上就代表 Dart 已走完
/// setup 與登入、[ChatService] 也已啟動。所以 App 被通知冷啟動時，目的地會等到首頁出現才處理；
/// 使用者還沒登入時就一直等到登入後（同一個 Activity 內；Activity 結束就丟棄）。首頁被其他畫面
/// 蓋住時它仍掛著，背景時點通知也從這裡處理。
///
/// 怎麼走（先關掉最上面的對話框與底部選單）：
/// - 私訊通知：最上面是聊天室或私訊畫面就留著，否則在最上面開聊天室；再向原生開啟該私訊
///   （[ChatService.startPrivateChat]）。之後全照 #55 的收斂規則：聊天室看到原生選定私訊就開私訊畫面，
///   已開著的私訊畫面則跟著換成新對象（同一人就不變）；畫面自己呼叫的 `startPrivateChat` 重複無害。
/// - @提及通知：回到公開聊天室——私訊畫面開著就關掉它（由聊天室照常結束私訊），沒有聊天室就開一個。
/// - 使用者原本在別的畫面（例如填到一半的健康回報）時，聊天室開在它上面，不關掉它。
///
/// 依靠 [ChatScreen.routeName] 與 [PrivateChatScreen.routeName] 認出聊天畫面：聊天室只能以
/// [ChatScreen.route] 開啟，私訊畫面只由聊天室開啟，所以聊天室若在 stack 上，一定在最上面或私訊畫面下面。
class ChatNavigationHost extends StatefulWidget {
  const ChatNavigationHost({super.key, required this.child, this.chatService});

  final Widget child;

  /// 測試用；預設為 app 層級的 [ChatService.instance]。
  final ChatService? chatService;

  @override
  State<ChatNavigationHost> createState() => _ChatNavigationHostState();
}

class _ChatNavigationHostState extends State<ChatNavigationHost> {
  /// 正在取走或處理一個點擊；期間到的新點擊等它完成後再處理。
  bool _busy = false;

  ChatService get _chat => widget.chatService ?? ChatService.instance;

  @override
  void initState() {
    super.initState();
    _chat.pendingNavigation.addListener(_onPending);
    // 首頁出現前（冷啟動、登入前）就有的點擊。
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPending());
  }

  @override
  void didUpdateWidget(ChatNavigationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.chatService ?? ChatService.instance;
    if (old != _chat) {
      old.pendingNavigation.removeListener(_onPending);
      _chat.pendingNavigation.addListener(_onPending);
    }
  }

  @override
  void dispose() {
    _chat.pendingNavigation.removeListener(_onPending);
    super.dispose();
  }

  Future<void> _onPending() async {
    if (_busy || !mounted || _chat.pendingNavigation.value == null) return;
    _busy = true;
    try {
      final ChatNavigation? navigation;
      try {
        navigation = await _chat.takePendingNavigation();
      } catch (e) {
        debugPrint('ChatNavigationHost: takePendingNavigation failed: $e');
        return;
      }
      // null：別人已取走，或這個 app 不認得的目的地。
      if (navigation != null && mounted) await _navigate(navigation);
    } finally {
      _busy = false;
    }
    // 處理期間又點了一次。
    if (mounted && _chat.pendingNavigation.value != null) unawaited(_onPending());
  }

  Future<void> _navigate(ChatNavigation navigation) async {
    final navigator = Navigator.of(context);
    String? top;
    navigator.popUntil((route) {
      if (route is PopupRoute) return false;
      top = route.settings.name;
      return true;
    });
    final chatOnTop = top == ChatScreen.routeName || top == PrivateChatScreen.routeName;

    switch (navigation) {
      case OpenPublicChat():
        if (top == PrivateChatScreen.routeName) {
          navigator.popUntil((route) => route.settings.name == ChatScreen.routeName || route.isFirst);
        } else if (!chatOnTop) {
          unawaited(navigator.push(ChatScreen.route(chatService: widget.chatService)));
        }
      case OpenPrivateChat(:final peerID):
        if (!chatOnTop) unawaited(navigator.push(ChatScreen.route(chatService: widget.chatService)));
        try {
          await _chat.startPrivateChat(peerID);
        } catch (e) {
          // 留在聊天室；使用者可以從 peer 列表再開一次。
          debugPrint('ChatNavigationHost: startPrivateChat failed: $e');
        }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
