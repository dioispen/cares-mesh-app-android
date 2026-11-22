import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/supply items.dart';
import 'package:flutter_ui/screens/supply_screen.dart';
import 'package:flutter_ui/services/supply_delivery.dart';

/// 物資卡片送出之後：結果由物資頁的 snackbar 說明，卡片自己不報成功，只依雲端是否記下
/// （[SupplyDelivery.recorded]）決定清不清空輸入。
void main() {
  const item = SupplyItem(id: 'water', name: '礦泉水', unit: '瓶', category: '食品飲水');

  Future<List<int>> submit(
    WidgetTester tester, {
    required bool pledge,
    required SupplyDelivery result,
  }) async {
    final sent = <int>[];
    Future<SupplyDelivery> send(int qty) async {
      sent.add(qty);
      return result;
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: pledge
            ? SupplyDonateCard(item: item, onPledge: send, initiallyExpanded: true)
            : SupplyRequestCard(item: item, onRequest: send, initiallyExpanded: true),
      ),
    ));
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text(pledge ? '承諾捐贈' : '申請'));
    await tester.pumpAndSettle();
    return sent;
  }

  for (final pledge in [false, true]) {
    final card = pledge ? 'donate card' : 'request card';

    testWidgets('$card: a submission the cloud did not record keeps the quantity and claims no success',
        (tester) async {
      final sent = await submit(
        tester,
        pledge: pledge,
        result: const SupplyDelivery(broadcastFailure: 'a', uploadFailure: 'b'),
      );

      expect(sent, [3]);
      expect(find.textContaining('成功'), findsNothing);
      expect(find.textContaining('感謝'), findsNothing);
      expect(find.widgetWithText(TextField, '3'), findsOneWidget);
    });

    testWidgets('$card: a submission queued offline counts as recorded and clears the quantity',
        (tester) async {
      final sent = await submit(tester, pledge: pledge, result: const SupplyDelivery(uploadQueued: true));

      expect(sent, [3]);
      expect(find.widgetWithText(TextField, '3'), findsNothing);
    });
  }
}
