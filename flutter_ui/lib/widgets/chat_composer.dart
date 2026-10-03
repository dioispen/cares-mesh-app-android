import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bitchat_bridge.dart';
import '../models/chat_suggestions.dart';
import '../services/chat_service.dart';
import 'chat_message_tile.dart';

/// 聊天輸入區：輸入列，加上公開聊天室的 `/` 指令與 `@` 提及補完清單（公開聊天室與私訊畫面共用）。
///
/// 照原生輸入框（`ChatScreen.kt` 的 `ChatInputSection`）的呼叫順序接原生核心：
/// 使用者每次改動文字都交給 [ChatService.updateInput]，送出被接受後清空輸入框。
///
/// [privateChat] 標明這是哪個私訊的輸入框（`PrivateChatFocus.peerID`），公開聊天室為 null。
/// 它隨送出與每次文字變化交給原生端：原生只在它的選定私訊與此相同時送出（否則回 false，文字留在
/// 輸入框），私訊輸入框的文字也存成該私訊的草稿、送出後清掉。
///
/// [withSuggestions]（公開聊天室）：補完由原生依輸入產生、經 [ChatService.suggestions] 顯示；選取
/// 補完時以原生回傳的文字取代輸入框、游標移到結尾；送出被接受後關閉補完；開啟時先關掉別的輸入框
/// 留下的補完。私訊畫面傳 false，照原生私訊畫面（`MeshPeerListSheet.kt` 的 `PrivateChatSheet`）：
/// 沒有補完清單、不動共用的補完狀態（原生端收到私訊輸入框的文字也只存草稿）；在私訊裡輸入的 `/`
/// 指令送出後原生照樣執行。
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.chat,
    this.controller,
    this.privateChat,
    this.enabled = true,
    this.withSuggestions = true,
    this.hintText = '輸入訊息...',
  });

  final ChatService chat;

  /// 由外部管理文字時傳入（例如私訊畫面放入草稿）；null 時自己建立。
  final TextEditingController? controller;

  final String? privateChat;

  /// 是否有 `/`、`@` 補完（公開聊天室）；私訊畫面為 false。建立後不應改變。
  final bool withSuggestions;

  /// false 時不能輸入也不能送出（例如私訊畫面還在等原生開啟對話）。
  final bool enabled;

  final String hintText;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  TextEditingController? _ownController;
  bool _sending = false;

  /// 補完清單最多約五列高（原生提及清單的上限），再多就捲動。
  static const _suggestionsMaxHeight = 252.0;

  TextEditingController get _controller => widget.controller ?? (_ownController ??= TextEditingController());

  ChatService get _chat => widget.chat;

  @override
  void initState() {
    super.initState();
    // 輸入框從空白開始；原生可能還留著上一個輸入框（例如 Activity 重建前）的補完。
    if (widget.withSuggestions) _fireAndForget(_chat.clearSuggestions(), 'clearSuggestions');
  }

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  /// 不等結果的 bridge 呼叫：失敗只記 log（例如沒有原生端），不打斷輸入。
  void _fireAndForget(Future<void> call, String what) {
    call.catchError((Object e) => debugPrint('ChatComposer: $what failed: $e'));
  }

  /// 文字原樣交給原生聊天核心（由它 trim、判斷指令與路由）；被接受才清空輸入框。
  Future<void> _sendMessage() async {
    final text = _controller.text;
    if (!widget.enabled || text.trim().isEmpty || _sending) return;
    _sending = true;
    final privateChat = widget.privateChat;
    try {
      final accepted = await _chat.sendMessage(text, privateChat: privateChat);
      if (accepted) {
        if (mounted) _controller.clear();
        // 程式清空輸入框不會觸發 onChanged，補完要明確關掉（原生輸入框也這樣做）；私訊輸入框
        // 沒有補完，以「文字變成空白」清掉這個私訊的草稿（原生私訊畫面送出後也這樣做）。
        if (privateChat == null) {
          if (widget.withSuggestions) _fireAndForget(_chat.clearSuggestions(), 'clearSuggestions');
        } else {
          _fireAndForget(_chat.updateInput('', privateChat: privateChat), 'updateInput');
        }
      }
    } catch (e) {
      debugPrint('ChatComposer: send failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_sendFailureText(e))));
    } finally {
      _sending = false;
    }
  }

  /// 送出失敗時告訴使用者的話：原生擋下的原因（[ChatErrors]）各有說明，其他錯誤請使用者稍後再試。
  /// 文字都留在輸入框。
  static String _sendFailureText(Object error) => switch (error) {
        PlatformException(code: ChatErrors.channelsUnsupported) => '頻道功能尚未支援，訊息沒有送出',
        _ => '訊息送出失敗，請稍後再試',
      };

  /// 使用者改動了文字：交給原生核心更新補完與草稿（與原生輸入框的 onValueChange 相同）。
  void _onInputChanged(String text) =>
      _fireAndForget(_chat.updateInput(text, privateChat: widget.privateChat), 'updateInput');

  /// 以原生回傳的文字取代輸入框，游標移到結尾（原生選取補完後的行為）。
  /// 程式設定文字不會觸發 onChanged，與原生相同：選取本身已讓原生關閉清單。
  void _replaceInput(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _selectCommand(CommandSuggestion suggestion) async {
    final before = _controller.text;
    try {
      final text = await _chat.selectCommandSuggestion(suggestion);
      // 原生已不再提供這個指令（null），或等待期間使用者又改了文字：不覆蓋。
      if (text == null || !mounted || _controller.text != before) return;
      _replaceInput(text);
    } catch (e) {
      debugPrint('ChatComposer: selectCommandSuggestion failed: $e');
    }
  }

  Future<void> _selectMention(String nickname) async {
    final before = _controller.text;
    try {
      final text = await _chat.selectMentionSuggestion(nickname, before);
      // 等待期間使用者又改了文字：原生是依舊文字算的，不覆蓋。
      if (!mounted || _controller.text != before) return;
      _replaceInput(text);
    } catch (e) {
      debugPrint('ChatComposer: selectMentionSuggestion failed: $e');
    }
  }

  /// 輸入框上方的補完清單。內容、順序與顯示條件都照原生：旗標打開且清單不是空的才顯示，
  /// 指令清單在上、提及清單在下。
  Widget _suggestionsPanel() => ValueListenableBuilder<ChatSuggestions>(
        valueListenable: _chat.suggestions,
        builder: (context, suggestions, _) {
          final showCommands = suggestions.commandsVisible;
          final showMentions = suggestions.mentionsVisible;
          if (!widget.enabled || (!showCommands && !showMentions)) return const SizedBox.shrink();
          // 點清單不算點到輸入框外，鍵盤與焦點留在輸入框。
          return TextFieldTapRegion(
            child: Container(
              constraints: const BoxConstraints(maxHeight: _suggestionsMaxHeight),
              decoration: const BoxDecoration(
                color: ChatPalette.card,
                border: Border(top: BorderSide(color: ChatPalette.divider)),
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  if (showCommands)
                    for (final command in suggestions.commands)
                      _CommandSuggestionTile(suggestion: command, onTap: () => _selectCommand(command)),
                  if (showCommands && showMentions) const Divider(height: 12, color: ChatPalette.divider),
                  if (showMentions)
                    for (final nickname in suggestions.mentions)
                      _MentionSuggestionTile(nickname: nickname, onTap: () => _selectMention(nickname)),
                ],
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.withSuggestions) _suggestionsPanel(),
        Container(
          color: ChatPalette.card,
          padding: const EdgeInsets.fromLTRB(14, 10, 100, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: widget.enabled,
                  style: const TextStyle(fontSize: 14, color: ChatPalette.textPrimary),
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    hintStyle: const TextStyle(color: ChatPalette.textSecondary, fontSize: 14),
                    filled: true,
                    fillColor: ChatPalette.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onChanged: _onInputChanged,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _sendMessage,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: widget.enabled ? ChatPalette.accent : ChatPalette.divider,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `/` 指令補完的一列，照原生 `CommandSuggestionItem`：指令與別名、參數說明、上游說明文字。
class _CommandSuggestionTile extends StatelessWidget {
  const _CommandSuggestionTile({required this.suggestion, required this.onTap});

  final CommandSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final syntax = suggestion.syntax;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Text(
              suggestion.label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: ChatPalette.accentDark,
              ),
            ),
            if (syntax != null) ...[
              const SizedBox(width: 8),
              Text(syntax, style: const TextStyle(fontSize: 12, color: ChatPalette.textSecondary)),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                suggestion.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: ChatPalette.textSecondary.withValues(alpha: 0.8)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `@` 提及補完的一列，照原生 `MentionSuggestionItem`：`@暱稱` 與「提及」。
class _MentionSuggestionTile extends StatelessWidget {
  const _MentionSuggestionTile({required this.nickname, required this.onTap});

  final String nickname;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '@$nickname',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ChatPalette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text('提及', style: TextStyle(fontSize: 12, color: ChatPalette.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
