import 'package:flutter/widgets.dart';

/// 聊天時間線捲到最新訊息（列表底部），公開聊天室與私訊畫面共用。
extension ScrollToEnd on ScrollController {
  /// 捲到底：[animate] 時以 250 ms ease-out 捲過去，否則直接跳到底。
  /// 還沒接上列表（例如沒有訊息、畫面上是提示文字）時什麼都不做。
  void scrollToEnd({bool animate = true}) {
    if (!hasClients) return;
    final target = position.maxScrollExtent;
    if (animate) {
      animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    } else {
      jumpTo(target);
    }
  }
}
