import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_message.dart';

/// 與 Kotlin `ChatSerialization.message` 輸出同形（見 ChatSerializationTest）。
Map<String, Object?> _fullMessage({Object? deliveryStatus}) => {
      'id': 'MSG-1',
      'sender': 'alice',
      'senderPeerID': '1122334455667788',
      'content': 'hello mesh',
      'timestamp': 1700000000123,
      'isPrivate': false,
      'mentions': ['me', 'bob'],
      'isRelay': true,
      'deliveryStatus': deliveryStatus,
      'isFromSelf': false,
      'isSystem': false,
    };

void main() {
  group('ChatMessage.fromMap', () {
    test('parses every bridge field', () {
      final m = ChatMessage.fromMap(_fullMessage())!;

      expect(m.id, 'MSG-1');
      expect(m.sender, 'alice');
      expect(m.senderPeerID, '1122334455667788');
      expect(m.content, 'hello mesh');
      expect(m.timestamp, DateTime.fromMillisecondsSinceEpoch(1700000000123));
      expect(m.isPrivate, isFalse);
      expect(m.mentions, ['me', 'bob']);
      expect(m.isRelay, isTrue);
      expect(m.deliveryStatus, isNull);
      expect(m.isFromSelf, isFalse);
      expect(m.isSystem, isFalse);
    });

    test('accepts the Map<Object?, Object?> shape the codec actually delivers', () {
      final raw = <Object?, Object?>{..._fullMessage(), 'isFromSelf': true};

      final m = ChatMessage.fromMap(raw)!;

      expect(m.isFromSelf, isTrue);
      expect(m.sender, 'alice');
    });

    test('falls back to defaults when every field is missing', () {
      final m = ChatMessage.fromMap(<String, Object?>{})!;

      expect(m.id, '');
      expect(m.sender, '');
      expect(m.senderPeerID, isNull);
      expect(m.content, '');
      expect(m.timestamp, DateTime.fromMillisecondsSinceEpoch(0));
      expect(m.isPrivate, isFalse);
      expect(m.mentions, isEmpty);
      expect(m.isRelay, isFalse);
      expect(m.deliveryStatus, isNull);
      expect(m.isFromSelf, isFalse);
      expect(m.isSystem, isFalse);
    });

    test('falls back to defaults when fields have the wrong type', () {
      final m = ChatMessage.fromMap({
        'id': 7,
        'sender': null,
        'senderPeerID': 42,
        'content': ['not', 'text'],
        'timestamp': '2024-01-01',
        'isPrivate': 'yes',
        'mentions': 'me',
        'isRelay': 1,
        'deliveryStatus': 'read',
        'isFromSelf': 'true',
        'isSystem': 0,
      })!;

      expect(m.id, '');
      expect(m.sender, '');
      expect(m.senderPeerID, isNull);
      expect(m.content, '');
      expect(m.timestamp, DateTime.fromMillisecondsSinceEpoch(0));
      expect(m.isPrivate, isFalse);
      expect(m.mentions, isEmpty);
      expect(m.isRelay, isFalse);
      expect(m.deliveryStatus, isNull);
      expect(m.isFromSelf, isFalse);
      expect(m.isSystem, isFalse);
    });

    test('keeps only the string entries of mentions', () {
      final m = ChatMessage.fromMap({..._fullMessage(), 'mentions': ['me', 3, null, 'bob']})!;

      expect(m.mentions, ['me', 'bob']);
    });

    test('returns null for anything that is not a map', () {
      expect(ChatMessage.fromMap(null), isNull);
      expect(ChatMessage.fromMap('hello'), isNull);
      expect(ChatMessage.fromMap([1, 2]), isNull);
    });
  });

  group('ChatMessage.listFrom', () {
    test('keeps timeline order and skips entries that are not maps', () {
      final list = ChatMessage.listFrom([
        {..._fullMessage(), 'id': 'A'},
        'garbage',
        null,
        {..._fullMessage(), 'id': 'B'},
      ])!;

      expect(list.map((m) => m.id), ['A', 'B']);
    });

    test('an empty list is an empty timeline', () {
      expect(ChatMessage.listFrom(const []), isEmpty);
    });

    test('returns null when the payload is not a list', () {
      expect(ChatMessage.listFrom(null), isNull);
      expect(ChatMessage.listFrom({'id': 'A'}), isNull);
      expect(ChatMessage.listFrom('A'), isNull);
    });
  });

  group('DeliveryStatus.fromMap', () {
    DeliveryStatus? parse(Object? raw) =>
        ChatMessage.fromMap(_fullMessage(deliveryStatus: raw))!.deliveryStatus;

    test('null means no status', () {
      expect(parse(null), isNull);
    });

    test('sending', () {
      expect(parse({'kind': 'sending'}), isA<DeliverySending>());
    });

    test('sent', () {
      expect(parse({'kind': 'sent'}), isA<DeliverySent>());
    });

    test('delivered carries recipient and time', () {
      final s = parse({'kind': 'delivered', 'to': 'bob', 'at': 1700000005000});

      expect(
        s,
        isA<DeliveryDelivered>()
            .having((d) => d.to, 'to', 'bob')
            .having((d) => d.at, 'at', DateTime.fromMillisecondsSinceEpoch(1700000005000)),
      );
    });

    test('read carries reader and time', () {
      final s = parse({'kind': 'read', 'by': 'bob', 'at': 1700000005000});

      expect(
        s,
        isA<DeliveryRead>()
            .having((d) => d.by, 'by', 'bob')
            .having((d) => d.at, 'at', DateTime.fromMillisecondsSinceEpoch(1700000005000)),
      );
    });

    test('failed carries its reason', () {
      expect(
        parse({'kind': 'failed', 'reason': 'Message expired before delivery'}),
        isA<DeliveryFailed>().having((d) => d.reason, 'reason', 'Message expired before delivery'),
      );
    });

    test('partially delivered carries reached and total', () {
      expect(
        parse({'kind': 'partiallyDelivered', 'reached': 2, 'total': 5}),
        isA<DeliveryPartiallyDelivered>()
            .having((d) => d.reached, 'reached', 2)
            .having((d) => d.total, 'total', 5),
      );
    });

    test('unknown kind is kept as unknown instead of throwing', () {
      expect(
        parse({'kind': 'teleported'}),
        isA<DeliveryUnknown>().having((d) => d.kind, 'kind', 'teleported'),
      );
    });

    test('missing kind is unknown', () {
      expect(parse(<String, Object?>{}), isA<DeliveryUnknown>().having((d) => d.kind, 'kind', ''));
    });

    test('missing or mistyped fields fall back to defaults', () {
      expect(
        parse({'kind': 'delivered'}),
        isA<DeliveryDelivered>()
            .having((d) => d.to, 'to', '')
            .having((d) => d.at, 'at', DateTime.fromMillisecondsSinceEpoch(0)),
      );
      expect(
        parse({'kind': 'partiallyDelivered', 'reached': '2', 'total': null}),
        isA<DeliveryPartiallyDelivered>()
            .having((d) => d.reached, 'reached', 0)
            .having((d) => d.total, 'total', 0),
      );
    });
  });
}
