import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/chat_peer.dart';
import '../models/chat_unread.dart';
import '../models/private_chat.dart';
import '../services/chat_service.dart';
import '../services/mascot_service.dart';
import '../widgets/chat_composer.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/peer_list_sheet.dart';
import 'private_chat_screen.dart';

/// 公開 mesh 聊天室。訊息與送出都經由 [ChatService]（原生 `ChatViewModel` 的投影），
/// 畫面本身不保存聊天狀態。輸入區是共用的 [ChatComposer]（公開聊天室不帶 `privateChat`）。
///
/// 私訊（#55）：原生聊天核心有「目前選定的私訊」時，它的輸入框文字會送成私訊，所以這個畫面
/// 依 [ChatService.selectedPrivateChat] 開關 [PrivateChatScreen]，不自行判斷：
/// - 從 peer 列表點一個 peer：關掉列表、立刻開啟私訊畫面，由私訊畫面向原生開啟對話
///   （與原生相同：先開畫面，畫面再呼叫 `startPrivateChat`）。
/// - 原生自己選定了私訊（公開聊天室輸入 `/m 暱稱`；點私訊通知時 `ChatNavigationHost` 也經由它）
///   而私訊畫面沒開：開啟它。
///   Activity 重建時私訊畫面隨 engine 消失、Dart 從第一個畫面重來，原生端會一併結束私訊
///   （Kotlin `ChatBridge.destroy`），不會留下沒人在看、卻仍被當成開著的私訊。
/// - 私訊畫面不論怎麼關閉（返回鍵、手勢、AppBar 返回、原生清除選定後自行關閉），都呼叫
///   [ChatService.endPrivateChat]；原生確認結束前不再依舊快照重開私訊畫面。
///
/// 未讀私訊（#56）照原生標頭：有未讀時 AppBar 最左側出現橘色信封，點了由原生挑出最新的未讀
/// 對話（`openLatestUnreadPrivateChat`）並開啟它；各 peer 的未讀數在 peer 列表上。開啟對話後由原生
/// 清除未讀，這裡只跟著快照。
///
/// 私訊畫面開著時公開輸入框在它下面、看不到；就算原生的選定私訊與畫面暫時不一致，
/// 原生端也只在選定私訊與輸入框相符時才送出（見 `BitchatBridge.sendMessage`），
/// 公開聊天室的文字不會被送成私訊。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.chatService});

  /// 測試用；預設為 app 層級的 [ChatService.instance]。
  final ChatService? chatService;

  /// 聊天室的 route 名稱：點通知時（`ChatNavigationHost`）靠它認出聊天室已經開著。
  static const routeName = '/chat';

  /// 開啟聊天室一律用這個 route（帶 [routeName]）。
  static Route<void> route({ChatService? chatService}) => MaterialPageRoute<void>(
        settings: const RouteSettings(name: routeName),
        builder: (_) => ChatScreen(chatService: chatService),
      );

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with RouteAware {
  final ScrollController _scrollController = ScrollController();
  String? _lastMessageId;

  /// 私訊畫面開著，或剛關閉、原生還沒確認結束私訊。
  bool _privateChatOpen = false;

  static const _bg = ChatPalette.bg;
  static const _card = ChatPalette.card;
  static const _textPrimary = ChatPalette.textPrimary;
  static const _textSecondary = ChatPalette.textSecondary;
  static const _accent = ChatPalette.accent;

  ChatService get _chat => widget.chatService ?? ChatService.instance;

  @override
  void initState() {
    super.initState();
    _lastMessageId = _lastIdOf(_chat.publicMessages.value);
    _chat.publicMessages.addListener(_onMessagesChanged);
    _chat.selectedPrivateChat.addListener(_onSelectedPrivateChatChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 打開聊天室時直接停在最新訊息
      _scrollToBottom(animate: false);
      // 這個畫面打開前原生就已選定私訊：開啟那個私訊。
      _onSelectedPrivateChatChanged();
    });
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.chatService ?? ChatService.instance;
    if (old != _chat) {
      old.publicMessages.removeListener(_onMessagesChanged);
      old.selectedPrivateChat.removeListener(_onSelectedPrivateChatChanged);
      _chat.publicMessages.addListener(_onMessagesChanged);
      _chat.selectedPrivateChat.addListener(_onSelectedPrivateChatChanged);
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
    _chat.selectedPrivateChat.removeListener(_onSelectedPrivateChatChanged);
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

  /// 原生選定了私訊而私訊畫面沒開：開啟它（`/m 暱稱` 等由原生選定的私訊）。
  void _onSelectedPrivateChatChanged() {
    final PrivateChatFocus? focus = _chat.selectedPrivateChat.value;
    if (focus == null || _privateChatOpen || !mounted) return;
    _openPrivateChat(focus.peerID, title: focus.displayName);
  }

  /// 開啟私訊畫面；它關閉後結束原生的私訊焦點。
  ///
  /// 私訊畫面關閉後 [_privateChatOpen] 維持 true，直到原生回覆 `endPrivateChat`：在那之前送達的
  /// 選定私訊快照是結束前的舊值，不能拿來重開私訊畫面。
  Future<void> _openPrivateChat(String peerID, {String? title}) async {
    if (_privateChatOpen) return;
    _privateChatOpen = true;
    // 私訊畫面可能在這個畫面之後才關閉（例如整個聊天室被帶離），結束時不再經由 widget 取。
    final chat = _chat;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: PrivateChatScreen.routeName),
        builder: (_) => PrivateChatScreen(peerID: peerID, title: title, chatService: chat),
      ));
    } finally {
      try {
        await chat.endPrivateChat();
      } catch (e) {
        debugPrint('ChatScreen: endPrivateChat failed: $e');
      }
      _privateChatOpen = false;
      // 補完不必清：私訊輸入框不動補完狀態（原生私訊畫面也不動），公開輸入框的文字與補完照舊。
    }
  }

  /// peer 列表點了某人：關掉列表，開啟與他的私訊。
  void _onPeerTap(BuildContext sheetContext, ChatPeer peer) {
    Navigator.of(sheetContext).pop();
    _openPrivateChat(peer.peerID, title: peer.displayName);
  }

  /// 未讀信封：原生挑出最新收到未讀私訊的對話（離線的對話也算），開啟它。
  Future<void> _openLatestUnread() async {
    if (_privateChatOpen) return;
    final String? conversationID;
    try {
      conversationID = await _chat.openLatestUnreadPrivateChat();
    } catch (e) {
      debugPrint('ChatScreen: openLatestUnreadPrivateChat failed: $e');
      return;
    }
    if (conversationID == null || !mounted) return;
    _openPrivateChat(conversationID);
  }

  /// AppBar 最左側的未讀私訊信封（對照原生標頭：未讀私訊信封排在最左、強調橘色、點了開啟最新的
  /// 未讀對話）。只在原生有未讀私訊時出現。
  Widget _unreadAction() => ValueListenableBuilder<ChatUnread>(
        valueListenable: _chat.unread,
        builder: (context, unread, _) {
          if (!unread.hasUnread) return const SizedBox.shrink();
          return IconButton(
            tooltip: '未讀私訊',
            onPressed: _openLatestUnread,
            icon: const Icon(Icons.mail, color: ChatPalette.unread),
          );
        },
      );

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

  /// 打開「附近的人」；列表隨 [ChatService.peerList] 即時更新，點一個人開啟私訊（離線的我的最愛
  /// 也可以，訊息由原生排隊），按尾端星號切換我的最愛（#58）。
  Future<void> _showPeerList() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (sheetContext) => PeerListSheet(
          peerList: _chat.peerList,
          onPeerTap: (peer) => _onPeerTap(sheetContext, peer),
          onFavoriteToggle: (peer) => _toggleFavorite(sheetContext, peer.peerID),
        ),
      );

  /// 交給原生切換我的最愛；列表保持開著，新的星號隨快照回來。
  Future<void> _toggleFavorite(BuildContext sheetContext, String peerID) async {
    try {
      await _chat.toggleFavorite(peerID);
    } catch (e) {
      debugPrint('ChatScreen: toggleFavorite failed: $e');
      if (sheetContext.mounted) {
        ScaffoldMessenger.of(sheetContext).showSnackBar(
          const SnackBar(content: Text('無法變更我的最愛，請稍後再試')),
        );
      }
    }
  }

  /// AppBar 最右側的線上人數（對照原生標頭的 `PeerCounter`：人數在最右、點了打開 peer 列表）。
  /// 原生端回報前不顯示；沒有人在線時變淡。
  Widget _peerCountAction() => ValueListenableBuilder<ChatPeerList?>(
        valueListenable: _chat.peerList,
        builder: (context, peerList, _) {
          if (peerList == null) return const SizedBox.shrink();
          final count = peerList.onlineCount;
          final color = count > 0 ? _accent : _textSecondary;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: '附近的人',
              child: TextButton.icon(
                onPressed: _showPeerList,
                style: TextButton.styleFrom(
                  foregroundColor: count > 0 ? _textPrimary : _textSecondary,
                  backgroundColor: _bg,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: const StadiumBorder(),
                ),
                icon: Icon(Icons.people_alt_outlined, size: 16, color: color),
                label: Text('$count', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
            Text(
              '防災互助通訊',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textPrimary),
            ),
            Text(
              '公開頻道 · 即時互助',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: _textSecondary),
            ),
          ],
        ),
        iconTheme: const IconThemeData(color: _textPrimary),
        actions: [_unreadAction(), _nicknameAction(), _peerCountAction()],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: ChatPalette.divider),
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
                    return const Center(
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
                    itemBuilder: (context, index) => ChatMessageTile(message: messages[index]),
                  );
                },
              ),
            ),
            ChatComposer(chat: _chat),
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

  static const _textPrimary = ChatPalette.textPrimary;
  static const _textSecondary = ChatPalette.textSecondary;
  static const _accent = ChatPalette.accent;

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
