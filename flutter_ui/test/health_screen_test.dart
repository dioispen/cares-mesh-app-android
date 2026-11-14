import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/protocol/ble_packet_decoder.dart';
import 'package:flutter_ui/screens/health_screen.dart';
import 'package:flutter_ui/services/health_report_publisher.dart';
import 'package:flutter_ui/services/mutual_aid_task_board.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_health_report_store.dart';
import 'support/in_memory_mutual_aid_task_store.dart';

final _user = AppUser(
  id: 'me',
  name: '我',
  phone: '0912345678',
  area: '台北市中正區',
  emergencyContactName: '王大明',
  emergencyContactPhone: '0987654321',
  emergencyContactRelation: '父親',
  registeredAt: DateTime(2024),
);

/// 載入中的轉圈不會停，pumpAndSettle 等不到：跑完分頁與底部面板的動畫就好。
Future<void> animate(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// 互救任務分頁：Firestore 與 BLE 兩路任務怎麼出現在畫面上。送出與任務規則各自有 module 的測試。
void main() {
  late InMemoryMutualAidTaskStore tasks;
  late StreamController<Map<String, dynamic>> events;

  Future<void> openMutualAidTab(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'app_user': jsonEncode(_user.toJson())});
    tasks = InMemoryMutualAidTaskStore();
    events = StreamController.broadcast();
    addTearDown(events.close);
    final board = MutualAidTaskBoard(
      store: tasks,
      events: () => events.stream,
      ownHandle: () async => 'aaaaaaaaaaaa',
      decode: (bytes) async => HealthReportPayload.decode(bytes),
    );
    final publisher = HealthReportPublisher(
      store: InMemoryHealthReportStore(),
      broadcast: ({required reporterHandle, required status, required lat, required lng, required sos}) async {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HealthScreen(publisher: publisher, taskBoard: board),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.tap(find.textContaining('互救任務'));
    await animate(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await animate(tester);
  }

  testWidgets('第一批任務還沒到時說載入中，不說附近沒有人需要協助', (tester) async {
    await openMutualAidTab(tester);

    expect(find.text('載入附近的求助任務…'), findsOneWidget);
    expect(find.text('附近目前無求助任務'), findsNothing);
  });

  testWidgets('讀取被規則擋下時說是權限問題', (tester) async {
    await openMutualAidTab(tester);

    tasks.pushReportsError(const TaskAccessDenied());
    await settle(tester);

    expect(find.text('你的帳號目前沒有權限查看互救任務清單'), findsOneWidget);
  });

  testWidgets('Firestore 的任務列出名字；BLE 收到的列成匿名回報', (tester) async {
    await openMutualAidTab(tester);

    tasks.pushReports([
      (id: 'alice', data: {'reporterId': 'alice', 'name': '陳小美', 'status': '重傷', 'reportTime': '2026-11-14T08:00:00Z'}),
    ]);
    events.add({
      'type': 'packet',
      'packetType': BlePacketType.healthReport,
      'payload': [0x02, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x01, 0x00, 0x00, 0x65, 0x53, 0xF1, 0x00],
    });
    await settle(tester);

    expect(find.text('陳小美'), findsOneWidget);
    expect(find.text('匿名回報 bbbb'), findsOneWidget);
  });

  testWidgets('接下 BLE 任務後切到進行中', (tester) async {
    await openMutualAidTab(tester);
    tasks.pushReports([]);
    events.add({
      'type': 'packet',
      'packetType': BlePacketType.healthReport,
      'payload': [0x02, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x02, 0x00, 0x00, 0x65, 0x53, 0xF1, 0x00],
    });
    await settle(tester);

    await tester.tap(find.text('匿名回報 bbbb'));
    await animate(tester);
    await tester.ensureVisible(find.text('前往協助'));
    await tester.tap(find.text('前往協助'));
    await settle(tester);

    expect(find.text('協助中'), findsOneWidget);
    expect(tasks.updates, isEmpty, reason: 'BLE 任務沒有 Firestore 文件');
  });
}
