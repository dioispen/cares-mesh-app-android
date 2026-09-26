import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/chat_service.dart';
import '../services/mascot_service.dart';

/// 公開 mesh 聊天室。訊息與送出都經由 [ChatService]（原生 `ChatViewModel` 的投影），
/// 畫面本身不保存聊天狀態。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.chatService});

  /// 測試用；預設為 app 層級的 [ChatService.instance]。
  final ChatService? chatService;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with RouteAware {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  String? _lastMessageId;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _accent = Color(0xFF9B88B3);

  ChatService get _chat => widget.chatService ?? ChatService.instance;

  @override
  void initState() {
    super.initState();
    _lastMessageId = _lastIdOf(_chat.publicMessages.value);
    _chat.publicMessages.addListener(_onMessagesChanged);
    // 打開聊天室時直接停在最新訊息
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animate: false));
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.chatService ?? ChatService.instance;
    if (old != _chat) {
      old.publicMessages.removeListener(_onMessagesChanged);
      _chat.publicMessages.addListener(_onMessagesChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    mascotRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    mascotRouteObserver.unsubscribe(this);
    _chat.publicMessages.removeListener(_onMessagesChanged);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didPush() => mascotOptionsNotifier.value = chatOptions;

  @override
  void didPopNext() => mascotOptionsNotifier.value = chatOptions;

  String? _lastIdOf(List<ChatMessage> messages) => messages.isEmpty ? null : messages.last.id;

  /// 有新訊息（包括自己送出、經原生回推的那則）時捲到底部。
  void _onMessagesChanged() {
    final lastId = _lastIdOf(_chat.publicMessages.value);
    if (lastId == _lastMessageId) return;
    _lastMessageId = lastId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom({bool animate = true}) {
    if (!mounted || !_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  /// 文字原樣交給原生聊天核心（由它 trim、判斷指令與路由）；被接受才清空輸入框。
  Future<void> _sendMessage() async {
    final text = _controller.text;
    if (text.trim().isEmpty || _sending) return;
    _sending = true;
    try {
      final accepted = await _chat.sendMessage(text);
      if (accepted && mounted) _controller.clear();
    } catch (e) {
      debugPrint('ChatScreen: send failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('訊息送出失敗，請稍後再試')),
      );
    } finally {
      _sending = false;
    }
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Color _avatarColor(String sender) {
    final colors = [
      const Color(0xFF6B9EAD),
      const Color(0xFF7AA67A),
      const Color(0xFFBF7A5A),
      const Color(0xFF9B88B3),
    ];
    return colors[sender.hashCode.abs() % colors.length];
  }

  String _initialOf(String sender) =>
      sender.characters.isEmpty ? '?' : sender.characters.first;

  /// 開啟 mesh 暱稱編輯器；它從目前的 mesh 暱稱開始，只送出使用者親手輸入的文字。
  Future<void> _editNickname() => showDialog<void>(
        context: context,
        builder: (_) => _MeshNicknameDialog(chat: _chat),
      );

  /// AppBar 右側的暱稱按鈕：附近裝置看到的名稱。原生端回報暱稱前不顯示。
  Widget _nicknameAction() => ValueListenableBuilder<String?>(
        valueListenable: _chat.nickname,
        builder: (context, nickname, _) {
          if (nickname == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Tooltip(
                message: '修改 mesh 暱稱',
                child: TextButton.icon(
                  onPressed: _editNickname,
                  style: TextButton.styleFrom(
                    foregroundColor: _textPrimary,
                    backgroundColor: _bg,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: const StadiumBorder(),
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 16, color: _accent),
                  label: Text(
                    nickname.isEmpty ? '設定暱稱' : '@$nickname',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('防災互助通訊', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textPrimary)),
            Text('公開頻道 · 即時互助', style: TextStyle(fontSize: 11, color: _textSecondary)),
          ],
        ),
        iconTheme: const IconThemeData(color: _textPrimary),
        actions: [_nicknameAction()],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: const Color(0xFFE8E0D5)),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ValueListenableBuilder<List<ChatMessage>>(
                valueListenable: _chat.publicMessages,
                builder: (context, messages, _) {
                  if (messages.isEmpty) {
                    return Center(
                      child: Text(
                        '附近還沒有訊息',
                        style: TextStyle(fontSize: 13, color: _textSecondary),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final isMe = msg.isFromSelf;
                      final isSystem = msg.isSystem;

                      if (isSystem) {
                        return Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 10),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8E0D5).withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              msg.content,
                              style: TextStyle(fontSize: 12, color: _textSecondary),
                            ),
                          ),
                        );
                      }

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Row(
                          mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (!isMe) ...[
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: _avatarColor(msg.sender),
                                child: Text(
                                  _initialOf(msg.sender),
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Column(
                              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                if (!isMe)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 2, bottom: 4),
                                    child: Text(msg.sender, style: TextStyle(fontSize: 11, color: _textSecondary)),
                                  ),
                                Container(
                                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: isMe ? _accent : _card,
                                    borderRadius: BorderRadius.only(
                                      topLeft: const Radius.circular(18),
                                      topRight: const Radius.circular(18),
                                      bottomLeft: Radius.circular(isMe ? 18 : 4),
                                      bottomRight: Radius.circular(isMe ? 4 : 18),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF3D2C1E).withValues(alpha: 0.06),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    msg.content,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: isMe ? Colors.white : _textPrimary,
                                      height: 1.45,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                                  child: Text(
                                    _formatTime(msg.timestamp),
                                    style: TextStyle(fontSize: 10, color: _textSecondary),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // 輸入列
            Container(
              color: _card,
              padding: const EdgeInsets.fromLTRB(14, 10, 100, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(fontSize: 14, color: _textPrimary),
                      decoration: InputDecoration(
                        hintText: '輸入訊息...',
                        hintStyle: TextStyle(color: _textSecondary, fontSize: 14),
                        filled: true,
                        fillColor: _bg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _sendMessage,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: _accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 修改 mesh 暱稱的對話框。
///
/// 只處理「附近裝置看到的名稱」，與帳號的真實姓名（`AppUser.name`）完全無關：
/// 初始值取自原生目前的 mesh 暱稱，送出的是使用者在這裡輸入的文字（ADR-0003）。
///
/// 文字原樣交給 `ChatViewModel.setNickname`，空白與長度沿用上游：上游的暱稱輸入
/// （`ChatHeader.kt` 的 `NicknameEditor`）不 trim、不限長度、允許空白，所以這裡也沒有
/// `maxLength` 或空白檢查。空白暱稱在 announce 時由 `NicknameProvider` 改用 peer ID；
/// 超過 255 UTF-8 bytes 時上游 `IdentityAnnouncement.encode()` 會放棄該次 announce（上游既有行為）。
class _MeshNicknameDialog extends StatefulWidget {
  const _MeshNicknameDialog({required this.chat});

  final ChatService chat;

  @override
  State<_MeshNicknameDialog> createState() => _MeshNicknameDialogState();
}

class _MeshNicknameDialogState extends State<_MeshNicknameDialog> {
  late final TextEditingController _controller;
  bool _saving = false;
  bool _failed = false;

  static const _textPrimary = _ChatScreenState._textPrimary;
  static const _textSecondary = _ChatScreenState._textSecondary;
  static const _accent = _ChatScreenState._accent;

  @override
  void initState() {
    super.initState();
    final current = widget.chat.nickname.value ?? '';
    _controller = TextEditingController(text: current)
      ..selection = TextSelection(baseOffset: 0, extentOffset: current.length);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.chat.setNickname(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // 包括 MissingPluginException：沒有原生端就是改不了，要讓使用者知道，而不是當作成功。
      debugPrint('ChatScreen: setNickname failed: $e');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('mesh 暱稱', style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w700)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_saving,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              prefixText: '@',
              errorText: _failed ? '暱稱更新失敗，請稍後再試' : null,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '附近的裝置（包括原生 bitchat）會看到這個名稱。暱稱會以明文廣播，請勿使用真實姓名。',
            style: TextStyle(fontSize: 12, color: _textSecondary, height: 1.4),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: _textSecondary)),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('儲存', style: TextStyle(color: _accent, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
