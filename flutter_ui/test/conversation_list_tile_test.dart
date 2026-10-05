import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_conversation.dart';
import 'package:flutter_ui/models/chat_peer.dart';
import 'package:flutter_ui/widgets/peer_list_sheet.dart';

/// The conversation rows of the peer list sheet (#73), on their own: how one row words what
/// Kotlin sends, as the native `ConversationRow` words it.
void main() {
  ChatConversation conversation({
    String preview = 'meet at the gym',
    ChatConversationPreviewType previewType = ChatConversationPreviewType.message,
    bool previewIsFromSelf = false,
    DateTime? timestamp,
    int unreadCount = 0,
    bool isOnline = false,
    ChatPeerConnection connection = ChatPeerConnection.offline,
    String displaySuffix = '',
    bool isFavorite = false,
    bool theyFavoritedUs = false,
  }) =>
      ChatConversation(
        conversationID: 'contact_dddd',
        displayName: 'dora',
        displaySuffix: displaySuffix,
        preview: preview,
        previewType: previewType,
        previewIsFromSelf: previewIsFromSelf,
        timestamp: timestamp,
        unreadCount: unreadCount,
        isOnline: isOnline,
        connection: connection,
        isFavorite: isFavorite,
        theyFavoritedUs: theyFavoritedUs,
      );

  group('conversationPreviewText', () {
    test('text is shown as upstream keeps it; a blank one as an ellipsis', () {
      expect(conversationPreviewText(conversation(preview: 'meet at the gym')), 'meet at the gym');
      expect(conversationPreviewText(conversation(preview: '  ')), '…');
    });

    test('media are worded as the native row words them', () {
      expect(conversationPreviewText(conversation(previewType: ChatConversationPreviewType.image)), '📷 傳送了一張圖片');
      expect(conversationPreviewText(conversation(previewType: ChatConversationPreviewType.audio)), '🎤 傳送了一則語音訊息');
      expect(
        conversationPreviewText(conversation(previewType: ChatConversationPreviewType.file, preview: 'map.pdf')),
        '📎 map.pdf',
      );
      expect(
        conversationPreviewText(conversation(previewType: ChatConversationPreviewType.file, preview: '')),
        '📎 傳送了一個檔案',
      );
    });

    test('our own latest message is prefixed, as the native "You:" is', () {
      expect(conversationPreviewText(conversation(preview: 'got it', previewIsFromSelf: true)), '你：got it');
      expect(
        conversationPreviewText(
          conversation(previewType: ChatConversationPreviewType.image, previewIsFromSelf: true),
        ),
        '你：📷 傳送了一張圖片',
      );
    });
  });

  group('conversationTimeLabel', () {
    final now = DateTime(2026, 10, 4, 15, 30);

    test('within the minute is just now, minutes and hours count back', () {
      expect(conversationTimeLabel(now.subtract(const Duration(seconds: 20)), now), '剛剛');
      expect(conversationTimeLabel(now.add(const Duration(minutes: 2)), now), '剛剛', reason: 'a peer clock ahead');
      expect(conversationTimeLabel(now.subtract(const Duration(minutes: 5)), now), '5 分鐘前');
      expect(conversationTimeLabel(now.subtract(const Duration(minutes: 59)), now), '59 分鐘前');
      expect(conversationTimeLabel(now.subtract(const Duration(hours: 1)), now), '1 小時前');
      expect(conversationTimeLabel(now.subtract(const Duration(hours: 23)), now), '23 小時前');
    });

    test('older ones count calendar days, then show the date', () {
      expect(conversationTimeLabel(DateTime(2026, 10, 3, 9), now), '昨天');
      expect(conversationTimeLabel(DateTime(2026, 10, 1, 18), now), '3 天前');
      expect(conversationTimeLabel(DateTime(2026, 9, 20, 18), now), '9月20日');
      expect(conversationTimeLabel(DateTime(2025, 12, 31, 18), now), '2025/12/31');
    });
  });

  group('ConversationListTile', () {
    Future<void> pump(WidgetTester tester, ChatConversation conversation, {VoidCallback? onTap}) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ConversationListTile(conversation: conversation, onTap: onTap)),
        ));

    testWidgets('shows the name with its dimmed suffix, the preview and the time', (tester) async {
      await pump(
        tester,
        conversation(displaySuffix: '#0a1b', timestamp: DateTime.now().subtract(const Duration(hours: 2))),
      );

      expect(find.text('dora#0a1b', findRichText: true), findsOneWidget);
      expect(find.text('meet at the gym'), findsOneWidget);
      expect(find.text('· 2 小時前'), findsOneWidget);
    });

    testWidgets('without a time only the preview is shown', (tester) async {
      await pump(tester, conversation());

      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('marks presence on the avatar: how an online peer is reached, or offline', (tester) async {
      await pump(tester, conversation(isOnline: true, connection: ChatPeerConnection.wifiAware));
      expect(find.byTooltip('在線 · Wi-Fi Aware 直連'), findsOneWidget);

      await pump(tester, conversation(isOnline: true, connection: ChatPeerConnection.routed));
      expect(find.byTooltip('在線 · 經 mesh 轉傳'), findsOneWidget);

      await pump(tester, conversation(isOnline: true, connection: ChatPeerConnection.unknown));
      expect(find.byTooltip('在線'), findsOneWidget);

      await pump(tester, conversation());
      expect(find.byTooltip('離線 · 不在 mesh 上'), findsOneWidget);
    });

    testWidgets('an unread conversation has its badge and a bold name', (tester) async {
      await pump(tester, conversation(unreadCount: 2));

      expect(find.byType(UnreadBadge), findsOneWidget);
      expect(find.byTooltip('2 則未讀私訊'), findsOneWidget);
    });

    testWidgets('the star is shown only when either side favourited the other', (tester) async {
      await pump(tester, conversation(isFavorite: true));
      expect(find.byIcon(Icons.star), findsOneWidget);

      await pump(tester, conversation(theyFavoritedUs: true));
      expect(find.byIcon(Icons.star_border), findsOneWidget);

      await pump(tester, conversation());
      expect(find.byIcon(Icons.star), findsNothing);
      expect(find.byIcon(Icons.star_border), findsNothing);
    });

    testWidgets('tapping the row calls back', (tester) async {
      var taps = 0;
      await pump(tester, conversation(), onTap: () => taps++);

      await tester.tap(find.text('dora'));

      expect(taps, 1);
    });
  });
}
