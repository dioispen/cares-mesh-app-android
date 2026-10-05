import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_conversation.dart';
import 'package:flutter_ui/models/chat_peer.dart';

const _contact = 'contact_dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

/// Exactly what Kotlin `ChatSerialization.conversation` produces.
Map<String, Object?> _conversation({
  String conversationID = _contact,
  String displayName = 'dora',
  String displaySuffix = '',
  String preview = 'meet at the gym',
  String previewType = 'message',
  bool previewIsFromSelf = false,
  int timestamp = 1700000000123,
  int unreadCount = 0,
  bool isOnline = false,
  String connection = 'offline',
  bool isFavorite = false,
  bool theyFavoritedUs = false,
}) =>
    {
      'conversationID': conversationID,
      'displayName': displayName,
      'displaySuffix': displaySuffix,
      'preview': preview,
      'previewType': previewType,
      'previewIsFromSelf': previewIsFromSelf,
      'timestamp': timestamp,
      'unreadCount': unreadCount,
      'isOnline': isOnline,
      'connection': connection,
      'isFavorite': isFavorite,
      'theyFavoritedUs': theyFavoritedUs,
    };

void main() {
  group('ChatConversation.fromMap', () {
    test('reads every bridge field', () {
      final conversation = ChatConversation.fromMap(_conversation(
        displaySuffix: '#0a1b',
        previewType: 'file',
        previewIsFromSelf: true,
        unreadCount: 3,
        isOnline: true,
        connection: 'bluetooth',
        isFavorite: true,
        theyFavoritedUs: true,
      ))!;

      expect(conversation.conversationID, _contact);
      expect(conversation.displayName, 'dora');
      expect(conversation.displaySuffix, '#0a1b');
      expect(conversation.preview, 'meet at the gym');
      expect(conversation.previewType, ChatConversationPreviewType.file);
      expect(conversation.previewIsFromSelf, isTrue);
      expect(conversation.timestamp, DateTime.fromMillisecondsSinceEpoch(1700000000123));
      expect(conversation.unreadCount, 3);
      expect(conversation.isOnline, isTrue);
      expect(conversation.connection, ChatPeerConnection.bluetooth);
      expect(conversation.isFavorite, isTrue);
      expect(conversation.theyFavoritedUs, isTrue);
    });

    test('an offline conversation is not online', () {
      final conversation = ChatConversation.fromMap(_conversation())!;

      expect(conversation.isOnline, isFalse);
      expect(conversation.connection, ChatPeerConnection.offline);
    });

    test('reads each preview kind; an unknown one is shown as text', () {
      ChatConversationPreviewType kind(Object? wire) =>
          ChatConversation.fromMap(_conversation()..['previewType'] = wire)!.previewType;

      expect(kind('message'), ChatConversationPreviewType.message);
      expect(kind('image'), ChatConversationPreviewType.image);
      expect(kind('audio'), ChatConversationPreviewType.audio);
      expect(kind('file'), ChatConversationPreviewType.file);
      expect(kind('sticker'), ChatConversationPreviewType.message);
      expect(kind(null), ChatConversationPreviewType.message);
    });

    test('missing fields fall back instead of throwing', () {
      final conversation = ChatConversation.fromMap({'conversationID': _contact})!;

      // Only for tolerance: a row always has something to show. Kotlin always sends a name.
      expect(conversation.displayName, _contact);
      expect(conversation.displaySuffix, '');
      expect(conversation.preview, '');
      expect(conversation.previewType, ChatConversationPreviewType.message);
      expect(conversation.previewIsFromSelf, isFalse);
      expect(conversation.timestamp, isNull, reason: 'no time is shown rather than a made-up one');
      expect(conversation.unreadCount, 0);
      expect(conversation.isOnline, isFalse, reason: 'presence is never guessed');
      expect(conversation.connection, ChatPeerConnection.unknown);
      expect(conversation.isFavorite, isFalse);
      expect(conversation.theyFavoritedUs, isFalse);
    });

    test('wrongly typed fields fall back instead of throwing', () {
      final conversation = ChatConversation.fromMap({
        'conversationID': _contact,
        'displayName': 42,
        'displaySuffix': false,
        'preview': ['hi'],
        'previewType': 7,
        'previewIsFromSelf': 'yes',
        'timestamp': '1700000000123',
        'unreadCount': -2,
        'isOnline': 1,
        'connection': true,
        'isFavorite': 'true',
        'theyFavoritedUs': 1,
      })!;

      expect(conversation.displayName, _contact);
      expect(conversation.displaySuffix, '');
      expect(conversation.preview, '');
      expect(conversation.previewType, ChatConversationPreviewType.message);
      expect(conversation.previewIsFromSelf, isFalse);
      expect(conversation.timestamp, isNull);
      expect(conversation.unreadCount, 0);
      expect(conversation.isOnline, isFalse);
      expect(conversation.connection, ChatPeerConnection.unknown);
      expect(conversation.isFavorite, isFalse);
      expect(conversation.theyFavoritedUs, isFalse);
    });

    test('an entry without a conversation ID is not a conversation', () {
      expect(ChatConversation.fromMap(_conversation()..remove('conversationID')), isNull);
      expect(ChatConversation.fromMap(_conversation(conversationID: '')), isNull);
      expect(ChatConversation.fromMap({'conversationID': 42}), isNull);
      expect(ChatConversation.fromMap(_contact), isNull);
      expect(ChatConversation.fromMap(null), isNull);
    });
  });

  group('ChatConversationList.fromEvent', () {
    Map<String, dynamic> event({Object? state = 'ready', Object? conversations}) => {
          'type': 'chat_conversations',
          'state': state,
          'conversations': conversations ??
              [
                _conversation(conversationID: 'contact_a', displayName: 'alice', isOnline: true, connection: 'routed'),
                _conversation(conversationID: 'contact_d', displayName: 'dora'),
              ],
        };

    test('reads the store state and the conversations in list order', () {
      final list = ChatConversationList.fromEvent(event())!;

      expect(list.state, ChatConversationStoreState.ready);
      expect(list.conversations.map((c) => c.displayName), ['alice', 'dora']);
    });

    test('online and offline conversations stay in the one order Kotlin sends', () {
      final list = ChatConversationList.fromEvent(event(conversations: [
        _conversation(conversationID: 'contact_d', isOnline: false),
        _conversation(conversationID: 'contact_a', isOnline: true, connection: 'bluetooth'),
      ]))!;

      expect(list.conversations.map((c) => c.conversationID), ['contact_d', 'contact_a'],
          reason: 'Dart must not regroup or re-sort');
    });

    test('reads each store state; a missing or unknown one is ready', () {
      ChatConversationStoreState stateOf(Object? wire) => ChatConversationList.fromEvent(event(state: wire))!.state;

      expect(stateOf('loading'), ChatConversationStoreState.loading);
      expect(stateOf('ready'), ChatConversationStoreState.ready);
      expect(stateOf('error'), ChatConversationStoreState.error);
      expect(stateOf('syncing'), ChatConversationStoreState.ready);
      expect(stateOf(null), ChatConversationStoreState.ready);
    });

    test('no conversations is an empty list', () {
      final list = ChatConversationList.fromEvent(event(conversations: []))!;

      expect(list.conversations, isEmpty);
    });

    test('entries that are not conversations are skipped, the rest kept in order', () {
      final list = ChatConversationList.fromEvent(event(conversations: [
        _conversation(conversationID: 'contact_a'),
        'junk',
        {'displayName': 'no id'},
        _conversation(conversationID: 'contact_d'),
      ]))!;

      expect(list.conversations.map((c) => c.conversationID), ['contact_a', 'contact_d']);
    });

    test('a malformed snapshot is rejected as a whole', () {
      expect(ChatConversationList.fromEvent({'type': 'chat_conversations'}), isNull);
      expect(ChatConversationList.fromEvent(event()..['conversations'] = 'nope'), isNull);
      expect(ChatConversationList.fromEvent(event()..['conversations'] = {'contact_a': {}}), isNull);
    });

    test('the conversations cannot be mutated by readers', () {
      final list = ChatConversationList.fromEvent(event())!;

      expect(() => list.conversations.clear(), throwsUnsupportedError);
    });
  });
}
