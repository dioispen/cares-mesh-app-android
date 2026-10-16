import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/supply items.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/screens/home_screen.dart';
import 'package:flutter_ui/screens/setup_screen.dart';
import 'package:flutter_ui/screens/sos_screen.dart';
import 'package:flutter_ui/screens/supply_screen.dart';
import 'package:flutter_ui/screens/verify_email_screen.dart';
import 'package:flutter_ui/services/chat_service.dart';
import 'package:flutter_ui/services/mascot_service.dart';
import 'package:flutter_ui/widgets/fill_or_scroll.dart';
import 'package:flutter_ui/widgets/mascot_assistant.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/screen_sizes.dart';

/// 各頁在 360×640 小螢幕＋字體 1.3 倍、平板橫向、鍵盤彈出時不會 overflow（#79）。
///
/// 防災地圖見 `shelter_source_footer_test.dart`，聊天室、暱稱對話框與私訊見 `chat_layout_test.dart`。
/// 登入、註冊、健康回報、防災知識與導覽頁不在這裡：前兩頁本來就可以捲動，健康回報在
/// `initState` 就連 Firestore，測試裡建立不起來。

/// 個人資料刻意給長的值：Firebase uid 28 字、緊急聯絡人一長串。
final _user = AppUser(
  id: 'Xq9ZkLmN0pQrStUvWxYz12345678',
  email: 'someone.with.a.rather.long.address@example.com',
  name: '王小明',
  phone: '0912345678',
  area: '臺北市大安區',
  emergencyContactName: '王大明',
  emergencyContactPhone: '0987654321',
  emergencyContactRelation: '父親',
  bloodType: 'O',
  medicalInfo: '對盤尼西林過敏，有氣喘病史，隨身攜帶吸入器',
  registeredAt: DateTime(2024, 1, 1),
);

void _withSavedUser() =>
    SharedPreferences.setMockInitialValues({'app_user': jsonEncode(_user.toJson())});

final _allCases = [...layoutCases, smallPhoneLargeText.withKeyboard()];

void main() {
  group('FillOrScroll', () {
    testWidgets('keeps content centred when it fits', (tester) async {
      useScreen(tester, tabletLandscape);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: FillOrScroll(
            child: Center(child: SizedBox(width: 100, height: 100, key: Key('box'))),
          ),
        ),
      ));

      expect(tester.getCenter(find.byKey(const Key('box'))), const Offset(640, 400));
    });

    testWidgets('scrolls instead of overflowing when the content is too tall', (tester) async {
      useScreen(tester, smallPhoneLargeText);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: FillOrScroll(
            fillWithFlex: true,
            child: Column(children: [SizedBox(height: 500), Spacer(), SizedBox(height: 500)]),
          ),
        ),
      ));

      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsOneWidget);
    });
  });

  group('SetupScreen', () {
    const methods = MethodChannel('com.bitchat/bridge/methods');
    const events = EventChannel('com.bitchat/bridge/events');

    /// 原生端：權限與 mesh 啟動照 [granted] 回答，其他呼叫一律成功。
    void fakeNative(WidgetTester tester, {required bool granted}) {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, (call) async {
        switch (call.method) {
          case 'checkPermissions':
          case 'startMesh':
            return granted;
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    }

    Future<void> pumpSetup(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SetupScreen()));
      await tester.pump();
      await tester.pump();
    }

    /// 搜尋中每兩秒會往下一步走；量完就拆掉畫面，不讓它真的去驗證身分。
    Future<void> unmount(WidgetTester tester) => tester.pumpWidget(const SizedBox());

    for (final screen in _allCases) {
      testWidgets('the permission prompt fits on $screen', (tester) async {
        fakeNative(tester, granted: false);
        useScreen(tester, screen);

        await pumpSetup(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('授權權限'), findsOneWidget);
      });

      testWidgets('searching for nearby nodes fits on $screen', (tester) async {
        fakeNative(tester, granted: true);
        useScreen(tester, screen);

        await pumpSetup(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('正在搜尋附近 Bitchat 節點...'), findsOneWidget);
        await unmount(tester);
      });
    }

    testWidgets('a long list of nearby devices still fits on a small phone with large text', (tester) async {
      fakeNative(tester, granted: true);
      final messenger = tester.binding.defaultBinaryMessenger;
      MockStreamHandlerEventSink? sink;
      messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, s) {
        sink = s;
      }));
      addTearDown(() => messenger.setMockStreamHandler(events, null));
      // 附近的人由 app 層級的 ChatService 提供，與聊天室同一份快照。
      await ChatService.instance.start();
      sink!.success({
        'type': 'chat_peers',
        'onlineCount': 6,
        'peopleCount': 6,
        'peers': [
          for (var i = 0; i < 6; i++)
            {
              'peerID': '${i}000000000000000',
              'nickname': 'neighbour$i',
              'displayName': 'neighbour$i',
              'displaySuffix': '',
              'connection': 'bluetooth',
            },
        ],
      });
      useScreen(tester, smallPhoneLargeText);

      await pumpSetup(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('附近已發現裝置：'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('檢查中...'), 50, scrollable: find.byType(Scrollable).first);
      expect(find.text('檢查中...'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('VerifyEmailScreen', () {
    for (final screen in _allCases) {
      testWidgets('fits on $screen', (tester) async {
        useScreen(tester, screen);

        await tester.pumpWidget(MaterialApp(home: VerifyEmailScreen(pendingUser: _user)));

        expect(tester.takeException(), isNull);
        expect(find.text('取消註冊'), findsOneWidget);
      });
    }

    testWidgets('the cancel button can still be scrolled to on a small phone', (tester) async {
      useScreen(tester, smallPhoneLargeText.withKeyboard());
      await tester.pumpWidget(MaterialApp(home: VerifyEmailScreen(pendingUser: _user)));

      await tester.scrollUntilVisible(find.text('取消註冊'), 50);

      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.text('取消註冊')).bottom,
          lessThanOrEqualTo(smallPhoneLargeText.size.height - 280));
    });
  });

  group('SOSScreen', () {
    setUp(_withSavedUser);

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

    for (final screen in layoutCases) {
      testWidgets('the SOS button and info card fit on $screen', (tester) async {
        fakeAudioPlugin(tester);
        useScreen(tester, screen);

        await tester.pumpWidget(const MaterialApp(home: SOSScreen()));
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);
        expect(find.text('王小明'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('on a tablet the SOS button stays between the banner and the info card', (tester) async {
      fakeAudioPlugin(tester);
      useScreen(tester, tabletLandscape);

      await tester.pumpWidget(const MaterialApp(home: SOSScreen()));
      await tester.pump(const Duration(milliseconds: 100));

      // 空間夠時照舊用 Spacer 撐開：資訊卡貼在畫面下方，不是緊接在按鈕下面。
      final card = tester.getRect(find.text('發送時間'));
      expect(card.bottom, greaterThan(tabletLandscape.size.height - 120));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('HomeScreen', () {
    setUp(_withSavedUser);

    for (final screen in layoutCases) {
      testWidgets('the home page fits on $screen', (tester) async {
        useScreen(tester, screen);

        await tester.pumpWidget(MaterialApp(navigatorObservers: [mascotRouteObserver], home: const HomeScreen()));
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
      });

      testWidgets('the profile sheet fits on $screen', (tester) async {
        useScreen(tester, screen);
        await tester.pumpWidget(MaterialApp(navigatorObservers: [mascotRouteObserver], home: const HomeScreen()));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('ID'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(_user.id), findsOneWidget, reason: 'the whole User ID is shown');
        await tester.scrollUntilVisible(find.text('登出'), 50,
            scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)));
        expect(find.text('登出'), findsOneWidget);
      });
    }
  });

  group('MascotAssistant', () {
    tearDown(() => mascotOptionsNotifier.value = const []);

    Future<void> pumpMascot(WidgetTester tester) async {
      mascotOptionsNotifier.value = homeOptions;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => Stack(children: [child!, const Positioned.fill(child: MascotAssistant())]),
        home: const Scaffold(body: TextField()),
      ));
    }

    Finder bubble() => find.byKey(const ValueKey('speech_bubble'));

    for (final screen in layoutCases) {
      testWidgets('the longest answer stays below the status bar on $screen', (tester) async {
        useScreen(tester, screen);
        await pumpMascot(tester);

        await tester.tap(find.byKey(const ValueKey('mascot_character')));
        await tester.pump();
        await tester.tap(find.text('物資捐贈怎麼用？'));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(tester.getRect(bubble()).top, greaterThanOrEqualTo(24));
      });
    }

    testWidgets('steps aside while the keyboard is up, and comes back as it was', (tester) async {
      useScreen(tester, smallPhoneLargeText);
      await pumpMascot(tester);
      await tester.tap(find.byKey(const ValueKey('mascot_character')));
      await tester.pump();
      expect(bubble(), findsOneWidget);

      setKeyboard(tester, 280);
      await tester.pump();
      expect(find.byKey(const ValueKey('mascot_character')), findsNothing);
      expect(bubble(), findsNothing);

      setKeyboard(tester, 0);
      await tester.pump();
      expect(bubble(), findsOneWidget);
    });
  });

  group('supply cards', () {
    const item = SupplyItem(
      id: 'water',
      name: '礦泉水（600ml 瓶裝）',
      unit: '公斤',
      category: '食品飲水',
      inventoryQty: 12000,
      totalRequestedQty: 99999,
      totalPledgedQty: 12345,
    );

    Future<void> pumpCards(WidgetTester tester) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SupplyRequestCard(item: item, onRequest: (qty) async {}),
                SupplyCustomRequestCard(onSubmit: (name, unit, qty) async {}),
                SupplyDonateCard(item: item, onPledge: (qty) async {}),
              ],
            ),
          ),
        ));

    for (final screen in _allCases) {
      testWidgets('large quantities fit on $screen', (tester) async {
        useScreen(tester, screen);

        await pumpCards(tester);

        expect(tester.takeException(), isNull);
      });
    }
  });
}
