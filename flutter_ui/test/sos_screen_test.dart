import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/screens/sos_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SOS 畫面在實機測試後的兩個調整：短點擊的提示不重複跳出，撤回 SOS 只做二次確認。
///
/// 送出（BLE mesh 與 Firestore）在測試裡沒有原生端與 Firebase，這裡只測不會送出的那幾條路。
final _user = AppUser(
  id: 'uid-alice',
  name: '王小明',
  phone: '0912345678',
  area: '臺北市大安區',
  emergencyContactName: '王大明',
  emergencyContactPhone: '0987654321',
  emergencyContactRelation: '父親',
  registeredAt: DateTime(2024, 1, 1),
);

const _holdHint = '請持續按住 3 秒才會送出求救';

void main() {
  /// 音效外掛在測試裡沒有原生端：一律回成功，畫面照常建立。
  void fakeAudioPlugin(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.allMessagesHandler = (channel, handler, message) {
      if (channel.startsWith('xyz.luan/audioplayers')) {
        return Future.value(const StandardMethodCodec().encodeSuccessEnvelope(null));
      }
      return handler?.call(message);
    };
    addTearDown(() => messenger.allMessagesHandler = null);
  }

  Future<void> openSosScreen(WidgetTester tester, {DateTime? raisedAt}) async {
    SharedPreferences.setMockInitialValues({
      'app_user': jsonEncode(_user.toJson()),
      if (raisedAt != null) 'sos_raised:${_user.id}': raisedAt.toUtc().toIso8601String(),
    });
    fakeAudioPlugin(tester);
    await tester.pumpWidget(const MaterialApp(home: SOSScreen()));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 按一下就放開：還沒按滿 3 秒。
  Future<void> shortTap(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.sos_rounded));
    await tester.pump(const Duration(milliseconds: 150));
  }

  group('短點擊 SOS 按鈕的提示', () {
    testWidgets('連續短點擊時不跳提示，停下來之後只跳一次', (tester) async {
      await openSosScreen(tester);

      for (var i = 0; i < 4; i++) {
        await shortTap(tester);
        expect(find.text(_holdHint), findsNothing, reason: '第 ${i + 1} 下');
      }

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300)); // SnackBar 進場動畫
      expect(find.text(_holdHint), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('提示還在畫面上時再短點擊，不會收掉重跳', (tester) async {
      await openSosScreen(tester);
      await shortTap(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      final shown = tester.element(find.byType(SnackBar));

      await shortTap(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.element(find.byType(SnackBar)), same(shown));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('撤回 SOS', () {
    testWidgets('只做二次確認，不必選 Status；取消就什麼都不送、SOS 仍在', (tester) async {
      await openSosScreen(tester, raisedAt: DateTime.now());

      // 待機的心跳動畫一直在跑，pumpAndSettle 等不到停下來，改等對話框動畫跑完。
      await tester.ensureVisible(find.text('撤回 SOS'));
      await tester.tap(find.text('撤回 SOS'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('同時回報你目前「安全」'), findsOneWidget);
      expect(find.text('輕傷'), findsNothing);
      expect(find.text('重傷'), findsNothing);

      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('撤回 SOS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
