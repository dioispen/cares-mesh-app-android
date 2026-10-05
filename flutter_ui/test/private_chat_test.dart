import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_message.dart';
import 'package:flutter_ui/models/private_chat.dart';

void main() {
  const alice = '1111111111111111';
  const contact = 'contact_aaaa';

  group('PrivateChatSelection.fromEvent', () {
    test('reads every field Kotlin sends', () {
      final focus = PrivateChatSelection.fromEvent({
        'type': 'chat_selected_private_peer',
        'peerID': alice,
        'conversationID': contact,
        'displayName': 'alice',
        'draft': 'see y',
      })!.focus!;

      expect([focus.peerID, focus.conversationID, focus.displayName, focus.draft], [alice, contact, 'alice', 'see y']);
      expect([focus.isFavorite, focus.theyFavoritedUs], [false, false]);
    });

    test('reads the header star\'s two directions (#58)', () {
      final focus = PrivateChatSelection.fromEvent({
        'peerID': contact,
        'conversationID': contact,
        'displayName': 'alice',
        'draft': '',
        'isFavorite': true,
        'theyFavoritedUs': false,
      })!.focus!;
      final theirs = PrivateChatSelection.fromEvent({'peerID': contact, 'theyFavoritedUs': true})!.focus!;

      expect([focus.isFavorite, focus.theyFavoritedUs], [true, false]);
      expect([theirs.isFavorite, theirs.theyFavoritedUs], [false, true]);
    });

    test('a missing or wrongly typed star is no favourite (#58)', () {
      final focus = PrivateChatSelection.fromEvent({'peerID': alice, 'isFavorite': 'yes', 'theyFavoritedUs': null})!.focus!;

      expect([focus.isFavorite, focus.theyFavoritedUs], [false, false]);
    });

    test('a null peerID is no private chat, not a malformed event', () {
      final selection = PrivateChatSelection.fromEvent({
        'type': 'chat_selected_private_peer',
        'peerID': null,
        'conversationID': null,
        'displayName': null,
        'draft': null,
      });

      expect(selection, isNotNull);
      expect(selection!.focus, isNull);
    });

    test('a missing or unusable peerID is malformed', () {
      for (final raw in <Object?>[null, 'nope', {'peerID': 42}, {'peerID': ''}]) {
        expect(PrivateChatSelection.fromEvent(raw), isNull, reason: '$raw');
      }
    });

    test('missing details fall back rather than fail', () {
      final focus = PrivateChatSelection.fromEvent({'peerID': alice, 'displayName': 3})!.focus!;

      expect(focus.conversationID, alice);
      expect(focus.displayName, '11111111');
      expect(focus.draft, '');
    });

    test('focuses with the same fields are equal', () {
      const a = PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'alice');
      const b = PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'alice');
      const renamed = PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'al');
      const favourited = PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'alice', isFavorite: true);
      const favouritedUs =
          PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'alice', theyFavoritedUs: true);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(renamed));
      // The screen rebuilds its star on these, so a change must not compare equal.
      expect(a, isNot(favourited));
      expect(a, isNot(favouritedUs));
    });
  });

  group('PrivateChatFocus.messagesIn', () {
    ChatMessage message(String id) =>
        ChatMessage(id: id, sender: 'alice', content: id, timestamp: DateTime(2024));

    test('reads the conversation key first', () {
      const focus = PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'alice');

      final messages = focus.messagesIn({
        contact: [message('C')],
        alice: [message('A')],
      });

      expect(messages.map((m) => m.id), ['C']);
    });

    test('falls back to the selected ID while Kotlin re-keys the conversation', () {
      const focus = PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'alice');

      expect(focus.messagesIn({alice: [message('A')]}).map((m) => m.id), ['A']);
    });

    test('a conversation with no messages yet is empty', () {
      const focus = PrivateChatFocus(peerID: alice, conversationID: contact, displayName: 'alice');

      expect(focus.messagesIn({'2222222222222222': [message('B')]}), isEmpty);
    });
  });

  group('PrivateChats.fromEvent', () {
    Map<String, Object?> msg(String id) => {'id': id, 'sender': 'alice', 'content': id, 'timestamp': 1};

    test('keeps every conversation and its order', () {
      final chats = PrivateChats.fromEvent({
        'type': 'chat_private_chats',
        'chats': {
          contact: [msg('P1'), msg('P2')],
          alice: [msg('P3')],
        },
      })!;

      expect(chats.keys, [contact, alice]);
      expect(chats[contact]!.map((m) => m.id), ['P1', 'P2']);
    });

    test('skips entries it cannot read and rejects a malformed snapshot', () {
      final chats = PrivateChats.fromEvent({
        'chats': {
          contact: [msg('P1')],
          alice: 'nope',
          7: [msg('P2')],
        },
      })!;

      expect(chats.keys, [contact]);
      expect(PrivateChats.fromEvent({'chats': 'nope'}), isNull);
      expect(PrivateChats.fromEvent({'type': 'chat_private_chats'}), isNull);
      expect(PrivateChats.fromEvent('nope'), isNull);
    });

    test('cannot be modified by readers', () {
      final chats = PrivateChats.fromEvent({
        'chats': {
          contact: [msg('P1')],
        },
      })!;

      expect(() => chats.clear(), throwsUnsupportedError);
      expect(() => chats[contact]!.clear(), throwsUnsupportedError);
    });
  });
}
