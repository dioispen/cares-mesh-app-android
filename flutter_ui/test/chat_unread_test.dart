import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_unread.dart';

const _contact = 'contact_aaaa';
const _offline = 'contact_bbbb';

/// Exactly what Kotlin `ChatSerialization.unreadEvent` produces.
Map<String, dynamic> _event({Object? hasUnread = true, Object? conversations}) => {
      'type': 'chat_unread',
      'hasUnread': hasUnread,
      'conversations': conversations ?? {_contact: 3, _offline: 1},
    };

void main() {
  group('ChatUnread.fromEvent', () {
    test('reads whether anything is unread and each conversation\'s count', () {
      final unread = ChatUnread.fromEvent(_event())!;

      expect(unread.hasUnread, isTrue);
      expect(unread.conversations, {_contact: 3, _offline: 1});
      expect(unread.countFor(_contact), 3);
    });

    test('a conversation without unread messages counts zero', () {
      expect(ChatUnread.fromEvent(_event())!.countFor('contact_cccc'), 0);
    });

    test('nothing unread is false and no counts', () {
      final unread = ChatUnread.fromEvent(_event(hasUnread: false, conversations: {}))!;

      expect(unread.hasUnread, isFalse);
      expect(unread.conversations, isEmpty);
    });

    test('the envelope follows hasUnread as Kotlin sends it, not the counts', () {
      // Upstream can mark a conversation unread before its badge has a count.
      final unread = ChatUnread.fromEvent(_event(hasUnread: true, conversations: {}))!;

      expect(unread.hasUnread, isTrue);
      expect(unread.conversations, isEmpty);
    });

    test('accepts the Map<Object?, Object?> shape the codec actually delivers', () {
      final unread = ChatUnread.fromEvent(_event(conversations: <Object?, Object?>{_contact: 2}))!;

      expect(unread.countFor(_contact), 2);
    });

    test('entries it cannot read are skipped, the rest kept', () {
      final unread = ChatUnread.fromEvent(_event(conversations: <Object?, Object?>{
        _contact: 2,
        42: 1,
        'contact_cccc': '3',
        'contact_dddd': 0,
        'contact_eeee': -1,
        _offline: 120,
      }))!;

      expect(unread.conversations, {_contact: 2, _offline: 120});
    });

    test('a malformed snapshot is rejected as a whole', () {
      expect(ChatUnread.fromEvent({'type': 'chat_unread'}), isNull);
      expect(ChatUnread.fromEvent(_event(hasUnread: 'yes')), isNull);
      expect(ChatUnread.fromEvent(_event(hasUnread: null)), isNull);
      expect(ChatUnread.fromEvent(_event(conversations: 'nope')), isNull);
    });

    test('the counts cannot be modified by readers', () {
      final unread = ChatUnread.fromEvent(_event())!;

      expect(() => unread.conversations.clear(), throwsUnsupportedError);
    });
  });

  test('none has nothing unread', () {
    expect(ChatUnread.none.hasUnread, isFalse);
    expect(ChatUnread.none.conversations, isEmpty);
  });
}
