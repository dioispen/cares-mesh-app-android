import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_message.dart';
import 'package:flutter_ui/widgets/chat_message_tile.dart';

/// A message map as Kotlin `ChatSerialization.message` sends it.
ChatMessage _message({
  bool isPrivate = true,
  bool isFromSelf = true,
  Map<String, Object?>? deliveryStatus = const {'kind': 'sent'},
}) =>
    ChatMessage.fromMap({
      'id': 'P1',
      'sender': isFromSelf ? 'me' : 'alice',
      'content': 'on my way',
      'timestamp': DateTime(2024, 5, 1, 9, 7).millisecondsSinceEpoch,
      'isPrivate': isPrivate,
      'isFromSelf': isFromSelf,
      'deliveryStatus': deliveryStatus,
    })!;

void main() {
  Future<void> pumpTile(WidgetTester tester, ChatMessage message) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ChatMessageTile(message: message))),
      );

  Finder mark() => find.byType(DeliveryStatusMark);

  /// The colours of the two checks, in order.
  List<Color?> checkColors(WidgetTester tester) {
    final text = tester.widget<Text>(find.descendant(of: mark(), matching: find.byType(Text)));
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text), ['✓', '✓'], reason: 'always two checks, as upstream draws them');
    return [for (final span in spans) span.style?.color];
  }

  const pending = ChatPalette.deliveryPending;
  const acknowledged = ChatPalette.deliveryAcknowledged;
  const failed = ChatPalette.deliveryFailed;

  group('delivery status of our own private messages (#56)', () {
    final cases = <String, (Map<String, Object?>, String, List<Color>)>{
      'sending': ({'kind': 'sending'}, '傳送中…', [pending, pending]),
      'sent': ({'kind': 'sent'}, '已送出', [pending, pending]),
      'delivered': ({'kind': 'delivered', 'to': 'bob', 'at': 1700000001000}, '已送達', [acknowledged, pending]),
      'partially delivered': ({'kind': 'partiallyDelivered', 'reached': 2, 'total': 3}, '已送達 2/3', [acknowledged, pending]),
      'read': ({'kind': 'read', 'by': 'bob', 'at': 1700000002000}, '已讀', [acknowledged, acknowledged]),
      'failed': (
        {'kind': 'failed', 'reason': 'Message expired before delivery'},
        '傳送失敗：Message expired before delivery',
        [failed, failed]
      ),
    };

    for (final MapEntry(key: name, value: (status, label, colors)) in cases.entries) {
      testWidgets('$name: upstream\'s two checks in its colours, explained by a tooltip', (tester) async {
        await pumpTile(tester, _message(deliveryStatus: status));

        expect(mark(), findsOneWidget);
        expect(checkColors(tester), colors);
        expect(find.byTooltip(label), findsOneWidget);
      });
    }

    testWidgets('the mark follows the time under the bubble', (tester) async {
      await pumpTile(tester, _message());

      final time = tester.getTopRight(find.text('09:07'));
      final check = tester.getTopLeft(mark());
      expect(check.dx, greaterThan(time.dx));
      expect(check.dy, moreOrLessEquals(time.dy, epsilon: 2));
    });

    testWidgets('a failure without a reason still says it failed', (tester) async {
      await pumpTile(tester, _message(deliveryStatus: {'kind': 'failed'}));

      expect(find.byTooltip('傳送失敗'), findsOneWidget);
    });
  });

  group('messages upstream draws no mark for', () {
    testWidgets('public messages, even our own', (tester) async {
      await pumpTile(tester, _message(isPrivate: false));

      expect(mark(), findsNothing);
    });

    testWidgets('private messages from others', (tester) async {
      await pumpTile(tester, _message(isFromSelf: false, deliveryStatus: {'kind': 'delivered'}));

      expect(mark(), findsNothing);
    });

    testWidgets('our private messages without a status', (tester) async {
      await pumpTile(tester, _message(deliveryStatus: null));

      expect(mark(), findsNothing);
    });

    testWidgets('a status this version does not know', (tester) async {
      await pumpTile(tester, _message(deliveryStatus: {'kind': 'teleported'}));

      expect(mark(), findsNothing);
    });
  });
}
