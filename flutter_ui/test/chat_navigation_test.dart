import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_navigation.dart';

const _contact = 'contact_aaaa';

void main() {
  group('ChatNavigation.fromMap', () {
    test('a private chat request carries the peer and the nickname the notification showed', () {
      final navigation = ChatNavigation.fromMap({
        'target': 'privateChat',
        'peerID': _contact,
        'senderNickname': 'alice',
      });

      expect(navigation, isA<OpenPrivateChat>());
      navigation as OpenPrivateChat;
      expect(navigation.peerID, _contact);
      expect(navigation.senderNickname, 'alice');
    });

    test('the nickname is optional', () {
      final navigation = ChatNavigation.fromMap({'target': 'privateChat', 'peerID': _contact, 'senderNickname': null});

      expect((navigation as OpenPrivateChat).senderNickname, isNull);
    });

    test('a public chat request has no fields of its own', () {
      expect(ChatNavigation.fromMap({'target': 'publicChat'}), isA<OpenPublicChat>());
    });

    test('accepts the Map<Object?, Object?> shape the codec actually delivers', () {
      final navigation = ChatNavigation.fromMap(<Object?, Object?>{'target': 'privateChat', 'peerID': _contact});

      expect((navigation as OpenPrivateChat).peerID, _contact);
    });

    test('nothing, a malformed request or one this app does not know goes nowhere', () {
      expect(ChatNavigation.fromMap(null), isNull);
      expect(ChatNavigation.fromMap('privateChat'), isNull);
      expect(ChatNavigation.fromMap({'peerID': _contact}), isNull);
      expect(ChatNavigation.fromMap({'target': 'privateChat'}), isNull);
      expect(ChatNavigation.fromMap({'target': 'privateChat', 'peerID': ''}), isNull);
      expect(ChatNavigation.fromMap({'target': 'privateChat', 'peerID': 42}), isNull);
      expect(ChatNavigation.fromMap({'target': 'geohashChat', 'geohash': 'u4pruyd'}), isNull);
    });
  });
}
