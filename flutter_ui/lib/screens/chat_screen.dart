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
