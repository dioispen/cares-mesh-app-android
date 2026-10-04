import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/widgets/favorite_toggle.dart';
import 'package:flutter_ui/widgets/scroll_to_end.dart';

/// The small actions the public chat and the private chat screen share.
void main() {
  group('ScrollController.scrollToEnd', () {
    Future<ScrollController> pumpList(WidgetTester tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ListView.builder(
          controller: controller,
          itemCount: 100,
          itemBuilder: (_, i) => SizedBox(height: 50, child: Text('row $i')),
        ),
      ));
      return controller;
    }

    testWidgets('jumps to the newest message', (tester) async {
      final controller = await pumpList(tester);

      controller.scrollToEnd(animate: false);

      expect(controller.offset, controller.position.maxScrollExtent);
      expect(controller.offset, greaterThan(0));
    });

    testWidgets('scrolls there when animated', (tester) async {
      final controller = await pumpList(tester);

      controller.scrollToEnd();
      expect(controller.offset, 0, reason: 'the animation has only started');
      await tester.pumpAndSettle();

      expect(controller.offset, controller.position.maxScrollExtent);
    });

    test('does nothing before the list is attached', () {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      controller.scrollToEnd();
      controller.scrollToEnd(animate: false);
    });
  });

  group('toggleFavoriteOrNotify', () {
    Future<BuildContext> pumpContext(WidgetTester tester) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const SizedBox.shrink();
        })),
      ));
      return context;
    }

    testWidgets('hands the ID to the chat service and shows nothing on success', (tester) async {
      final toggled = <String>[];
      final chat = ChatService(toggleFavorite: (peerID) async => toggled.add(peerID));
      final context = await pumpContext(tester);

      await toggleFavoriteOrNotify(context, chat, 'abcd', logTag: 'test');
      await tester.pump();

      expect(toggled, ['abcd']);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('tells the user when the native side fails', (tester) async {
      final chat = ChatService(toggleFavorite: (_) async => throw PlatformException(code: 'INVALID_ARGUMENT'));
      final context = await pumpContext(tester);

      await toggleFavoriteOrNotify(context, chat, 'abcd', logTag: 'test');
      await tester.pump();

      expect(find.text('無法變更我的最愛，請稍後再試'), findsOneWidget);
    });
  });
}
