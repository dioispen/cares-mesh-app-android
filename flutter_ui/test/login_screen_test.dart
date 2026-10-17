import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/login_screen.dart';

/// A field that fails validation stays visible: it keeps an outline and its label is not turned
/// red; the reason is written under the field.
void main() {
  Future<void> submitEmpty(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5C3D2E))),
      home: const LoginScreen(),
    ));
    await tester.ensureVisible(find.widgetWithText(ElevatedButton, '登入'));
    await tester.tap(find.widgetWithText(ElevatedButton, '登入'));
    await tester.pumpAndSettle();
  }

  InputDecorator decoratorOf(WidgetTester tester, String label) => tester.widget<InputDecorator>(
      find.ancestor(of: find.text(label), matching: find.byType(InputDecorator)));

  testWidgets('a field that fails validation keeps its outline', (tester) async {
    await submitEmpty(tester);

    expect(find.text('請輸入電子郵件'), findsOneWidget);
    expect(find.text('請輸入密碼'), findsOneWidget);
    for (final label in ['電子郵件', '密碼']) {
      final decorator = decoratorOf(tester, label);
      expect(decorator.decoration.errorText, isNotNull, reason: '$label is in its error state');
      for (final border in [decorator.decoration.errorBorder, decorator.decoration.focusedErrorBorder]) {
        expect(border, isNotNull, reason: 'without it $label falls back to its borderless border');
        expect(border!.borderSide.style, BorderStyle.solid);
        expect(border.borderSide.width, greaterThan(0));
      }
    }
  });

  testWidgets('the labels are not turned red by a validation error', (tester) async {
    await submitEmpty(tester);
    final errorColor = Theme.of(tester.element(find.byType(LoginScreen))).colorScheme.error;

    for (final label in ['電子郵件', '密碼']) {
      final color = DefaultTextStyle.of(tester.element(find.text(label))).style.color;
      expect(color, isNot(errorColor), reason: label);
      expect(color, const Color(0xFF8C7B6E), reason: label);
    }
    // The reason itself is still shown in the error colour.
    expect(find.text('請輸入電子郵件'), findsOneWidget);
  });
}
