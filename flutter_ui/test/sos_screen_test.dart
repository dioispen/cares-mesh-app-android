import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/screens/sos_screen.dart';
import 'package:flutter_ui/services/health_report_publisher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_health_report_store.dart';

/// SOS 畫面在實機測試後的兩個調整：短點擊的提示不重複跳出，撤回 SOS 只做二次確認。
///
/// 送出的細節由 [HealthReportPublisher] 自己的測試負責，這裡只看畫面怎麼反映結果。
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

  Future<void> openSosScreen(WidgetTester tester, {DateTime? raisedAt, HealthReportPublisher? publisher}) async {
    SharedPreferences.setMockInitialValues({
      'app_user': jsonEncode(_user.toJson()),
      if (raisedAt != null) 'sos_raised:${_user.id}': raisedAt.toUtc().toIso8601String(),
    });
    fakeAudioPlugin(tester);
    await tester.pumpWidget(MaterialApp(home: SOSScreen(publisher: publisher)));
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

  group('舉起 SOS', () {
    testWidgets('送到了但沒有附上位置：有但書，不顯示完成的勾', (tester) async {
      final store = InMemoryHealthReportStore();
      final publisher = HealthReportPublisher(
        store: store,
        broadcast: ({required reporterHandle, required status, required lat, required lng, required sos}) async {},
      );
      // 測試裡沒有定位外掛，所以這次沒有位置。
      await openSosScreen(tester, publisher: publisher);

      final hold = await tester.startGesture(tester.getCenter(find.byIcon(Icons.sos_rounded)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 100));
      await hold.up();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(store.detail['sos'], isTrue);
      expect(find.textContaining('沒有附上位置'), findsWidgets);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
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

    /// 確認撤回之後，等送出完成、提示跳出來。
    Future<void> confirmWithdraw(WidgetTester tester) async {
      await tester.ensureVisible(find.text('撤回 SOS'));
      await tester.tap(find.text('撤回 SOS'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('我已安全，撤回'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('確認之後回報安全，畫面回到還沒舉起', (tester) async {
      final store = InMemoryHealthReportStore();
      final sent = <String>[];
      final publisher = HealthReportPublisher(
        store: store,
        broadcast: ({required reporterHandle, required status, required lat, required lng, required sos}) async {
          sent.add(status);
        },
      );
      await openSosScreen(tester, raisedAt: DateTime.now(), publisher: publisher);

      await confirmWithdraw(tester);

      expect(sent, ['安全']);
      expect(store.detail['sos'], isFalse);
      expect(find.textContaining('已撤回 SOS'), findsOneWidget);
      expect(find.text('撤回 SOS'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('誰都沒收到撤回時要說出來，SOS 仍在', (tester) async {
      final publisher = HealthReportPublisher(
        store: InMemoryHealthReportStore()..writeError = StateError('denied'),
        broadcast: ({required reporterHandle, required status, required lat, required lng, required sos}) async {
          throw StateError('mesh');
        },
      );
      await openSosScreen(tester, raisedAt: DateTime.now(), publisher: publisher);

      await confirmWithdraw(tester);

      expect(find.textContaining('撤回失敗，SOS 仍在'), findsOneWidget);
      expect(find.text('撤回 SOS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('暫存的撤回之後才失敗，也要告訴使用者', (tester) async {
      final store = InMemoryHealthReportStore()..holdAcks = true;
      final publisher = HealthReportPublisher(
        store: store,
        uploadTimeout: const Duration(milliseconds: 1),
        broadcast: ({required reporterHandle, required status, required lat, required lng, required sos}) async {},
      );
      await openSosScreen(tester, raisedAt: DateTime.now(), publisher: publisher);

      await confirmWithdraw(tester);
      expect(find.textContaining('已撤回 SOS'), findsOneWidget);

      store.releaseAcks(error: StateError('denied'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('暫存的撤回沒有上傳到雲端。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
