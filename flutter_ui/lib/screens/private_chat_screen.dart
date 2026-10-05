import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/private_chat.dart';
import '../services/chat_service.dart';
import '../widgets/chat_composer.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/favorite_star_button.dart';
import '../widgets/favorite_toggle.dart';
import '../widgets/scroll_to_end.dart';

/// 私訊畫面（#55）：原生聊天核心「目前選定的私訊」（[ChatService.selectedPrivateChat]）的投影。
///
/// 開法與原生私訊畫面（`MeshPeerListSheet.kt` 的 `PrivateChatSheet`）相同：以 [peerID] 開啟，
/// 開啟時呼叫一次 [ChatService.startPrivateChat]（原生是 `LaunchedEffect(peerID)`），由原生載入
/// 紀錄、設為選定對象。原生回覆前畫面只顯示 [title] 與等待中，輸入框不能用。
///
/// 之後畫面完全跟隨原生的選定私訊，不自行判斷：
/// - 標題、訊息、輸入框所屬的私訊、AppBar 的我的最愛星號（#58）都取自它（[PrivateChatFocus]）。
///   對方離線也一樣能開、能送：原生把訊息排隊，對方回到 mesh 後送達。
/// - 原生改選了別的對話（在這裡輸入 `/m 別人`，或 peer ID 正規化成 `contact_…` 對話）就跟著換；
///   輸入框是空的時放入新對話的草稿。
/// - 原生不再有選定私訊（開啟被拒，例如對方已封鎖；或 `/block`、刪除對話、panic 清除）就自行關閉。
///
/// 關閉後——不論是返回鍵、手勢、AppBar 返回還是上面的自行關閉——由開啟它的 `ChatScreen`
/// 呼叫 [ChatService.endPrivateChat]，確保之後公開聊天室的文字不會被送成私訊。
class PrivateChatScreen extends StatefulWidget {
  const PrivateChatScreen({super.key, required this.peerID, this.title, this.chatService});

  /// 要開啟的 peer ID（來自 peer 列表）或原生選定的對話 ID，交給 `chat_startPrivateChat`。
  final String peerID;

  /// 原生回覆前的暫時標題（例如 peer 列表上的名稱）。
  final String? title;

  /// 測試用；預設為 app 層級的 [ChatService.instance]。
  final ChatService? chatService;

  /// 私訊畫面的 route 名稱（只由 `ChatScreen` 開啟，所以它下面一定是聊天室）：點通知時
  /// （`ChatNavigationHost`）靠它認出私訊畫面開著。
  static const routeName = '/chat/private';

  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// 開啟請求已有結果（成功、被拒或失敗）；在這之前選定私訊的舊值不算數。
  bool _started = false;
  bool _closing = false;

  /// 目前顯示的對話（原生的選定私訊）；原生回覆前為 null。
  PrivateChatFocus? _focus;
  String? _lastMessageId;

  ChatService get _chat => widget.chatService ?? ChatService.instance;

  @override
  void initState() {
    super.initState();
    _chat.selectedPrivateChat.addListener(_onFocusChanged);
    _chat.privateChats.addListener(_onMessagesChanged);
    _start();
  }

  @override
  void dispose() {
    _chat.selectedPrivateChat.removeListener(_onFocusChanged);
    _chat.privateChats.removeListener(_onMessagesChanged);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await _chat.startPrivateChat(widget.peerID);
    } catch (e) {
      debugPrint('PrivateChatScreen: startPrivateChat failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無法開啟私訊，請稍後再試')),
        );
      }
    }
    if (!mounted) return;
    _started = true;
    _onFocusChanged();
  }

  /// 跟隨原生的選定私訊：沒有了就關閉，換了就改顯示新的對話。
  void _onFocusChanged() {
    if (!_started || _closing || !mounted) return;
    final focus = _chat.selectedPrivateChat.value;
    if (focus == null) {
      _close();
      return;
    }
    final previous = _focus;
    setState(() => _focus = focus);
    if (previous?.peerID != focus.peerID) {
      if (_controller.text.isEmpty) {
        _controller.value = TextEditingValue(
          text: focus.draft,
          selection: TextSelection.collapsed(offset: focus.draft.length),
        );
      }
      _lastMessageId = null;
      _onMessagesChanged();
    }
  }

  /// 原生已不再選定私訊：關掉這個畫面（以及它上面可能開著的對話框）。
  void _close() {
    _closing = true;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    navigator.popUntil((r) => r == route);
    navigator.pop();
  }

  List<ChatMessage> _messagesOf(Map<String, List<ChatMessage>> chats) => _focus?.messagesIn(chats) ?? const [];

  /// 有新訊息（包括自己送出、經原生回推的那則）時捲到底部。
  void _onMessagesChanged() {
    final messages = _messagesOf(_chat.privateChats.value);
    final lastId = messages.isEmpty ? null : messages.last.id;
    if (lastId == _lastMessageId) return;
    final first = _lastMessageId == null;
    _lastMessageId = lastId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollController.scrollToEnd(animate: !first);
    });
  }

  Widget _timeline() {
    if (_focus == null) {
      return const Center(child: CircularProgressIndicator(color: ChatPalette.accent));
    }
    return ValueListenableBuilder<Map<String, List<ChatMessage>>>(
      valueListenable: _chat.privateChats,
      builder: (context, chats, _) {
        final messages = _messagesOf(chats);
        if (messages.isEmpty) {
          return const Center(
            child: Text('還沒有私訊', style: TextStyle(fontSize: 13, color: ChatPalette.textSecondary)),
          );
        }
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: messages.length,
          itemBuilder: (context, index) => ChatMessageTile(message: messages[index]),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final focus = _focus;
    final name = focus?.displayName ?? widget.title ?? '';
    return Scaffold(
      backgroundColor: ChatPalette.bg,
      appBar: AppBar(
        backgroundColor: ChatPalette.card,
        iconTheme: const IconThemeData(color: ChatPalette.textPrimary),
        actions: [
          // 原生私訊標頭的星號（#58）：原生回覆開啟前還不知道是哪個對話，不顯示。
          if (focus != null)
            // 用原生選定的 ID 切換，與原生標頭相同。
            FavoriteStarButton(
              isFavorite: focus.isFavorite,
              theyFavoritedUs: focus.theyFavoritedUs,
              onPressed: () => toggleFavoriteOrNotify(context, _chat, focus.peerID, logTag: 'PrivateChatScreen'),
            ),
        ],
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ChatPalette.textPrimary),
            ),
            const Text(
              '私訊',
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: ChatPalette.textSecondary),
            ),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: ChatPalette.divider),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _timeline()),
            // 原生私訊畫面沒有 `/`、`@` 補完（`/` 指令送出後仍由原生執行）。
            ChatComposer(
              chat: _chat,
              controller: _controller,
              privateChat: focus?.peerID,
              enabled: focus != null,
              withSuggestions: false,
              hintText: name.isEmpty ? '輸入私訊...' : '傳私訊給 $name...',
            ),
          ],
        ),
      ),
    );
  }
}
