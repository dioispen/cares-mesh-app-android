import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/protocol/ble_packet_decoder.dart';
import 'package:flutter_ui/services/mutual_aid_task_board.dart';
import 'package:flutter_ui/services/mutual_aid_tasks.dart';

import 'support/in_memory_mutual_aid_task_store.dart';

const _myHandle = 'aaaaaaaaaaaa';

/// Health Report 的 Broadcast Tier（版本 2），格式見 `health_report_payload_test.dart` 的權威向量。
List<int> _payload({
  required String handle,
  int status = 2,
  bool sos = false,
  String? geohash = 'wsqqqm',
  int secs = 1700000000,
}) => [
  0x02,
  for (var i = 0; i < 12; i += 2) int.parse(handle.substring(i, i + 2), radix: 16),
  status,
  sos ? 0x01 : 0x00,
  geohash?.length ?? 0,
  ...?geohash?.codeUnits,
  (secs >> 24) & 0xFF,
  (secs >> 16) & 0xFF,
  (secs >> 8) & 0xFF,
  secs & 0xFF,
];

/// 原生端轉給 Flutter 的封包事件。
Map<String, dynamic> _packet(List<int> payload, {int type = BlePacketType.healthReport}) => {
  'type': 'packet',
  'packetType': type,
  'payload': payload,
};

ReportEntry _report(String uid, {String status = '重傷', String? taskStatus, String? helperId}) => (
  id: uid,
  data: {
    'reporterId': uid,
    'name': '名字$uid',
    'status': status,
    'lat': 25.0,
    'lng': 121.5,
    'reportTime': '2026-11-14T08:00:00Z',
    'taskStatus': ?taskStatus,
    'helperId': ?helperId,
  },
);

void main() {
  late InMemoryMutualAidTaskStore store;
  late StreamController<Map<String, dynamic>> events;
  late MutualAidTaskBoard board;

  setUp(() {
    store = InMemoryMutualAidTaskStore();
    events = StreamController.broadcast();
    board = MutualAidTaskBoard(
      store: store,
      events: () => events.stream,
      ownHandle: () async => _myHandle,
      decode: (bytes) async => HealthReportPayload.decode(bytes),
    );
  });

  tearDown(() => events.close());

  /// 開著清單，回傳最近一次的內容。
  Future<MutualAidTaskList Function()> watch() async {
    MutualAidTaskList? latest;
    final subscription = board.watch().listen((list) => latest = list);
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    return () => latest!;
  }

  Future<void> receive(Map<String, dynamic> event) async {
    events.add(event);
    await pumpEventQueue();
  }

  group('Firestore 的任務', () {
    test('第一批文件還沒到時是載入中；到了之後列出別人的任務', () async {
      final list = await watch();
      expect(list().loaded, isFalse);

      store.pushReports([_report('alice'), _report('me')]);
      await pumpEventQueue();

      expect(list().loaded, isTrue);
      expect(list().tasksNear(currentUserId: 'me').map((t) => t.userId), ['alice']);
    });

    test('讀取被規則擋下時說是權限問題，其他錯誤說載入失敗', () async {
      final list = await watch();

      store.pushReportsError(const TaskAccessDenied());
      await pumpEventQueue();
      expect(list().error, TaskListError.denied);

      store.pushReportsError(StateError('unavailable'));
      await pumpEventQueue();
      expect(list().error, TaskListError.failed);
      expect(list().loaded, isTrue);

      store.pushReports([_report('alice')]);
      await pumpEventQueue();
      expect(list().error, isNull);
    });

    test('還不知道自己是誰時不列任何 Firestore 任務，免得閃出自己那筆', () async {
      final list = await watch();
      store.pushReports([_report('alice'), _report('me')]);
      await pumpEventQueue();

      expect(list().tasksNear(currentUserId: null), isEmpty);
    });

    test('rescuers 名單上的帳號是 Verified Rescuer', () async {
      store.rescuers = {'me'};

      expect(await board.isVerifiedRescuer('me'), isTrue);
      expect(await board.isVerifiedRescuer('someone'), isFalse);
    });

    test('關掉清單之後不再監聽 Firestore', () async {
      final subscription = board.watch().listen((_) {});
      await pumpEventQueue();
      expect(store.watchingReports, isTrue);

      await subscription.cancel();

      expect(store.watchingReports, isFalse);
    });
  });

  group('BLE 收到的 Health Report', () {
    test('別人的回報列成匿名任務，距離用畫面給的位置算', () async {
      board.startCollecting();
      final list = await watch();

      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb', status: 2, sos: true)));

      final task = list().tasksNear(lat: 25.0, lng: 121.5).single;
      expect(task.isBle, isTrue);
      expect(task.userId, 'bbbbbbbbbbbb');
      expect(task.injury, '重傷');
      expect(task.sos, isTrue);
      expect(task.distanceKm, isNotNull);
      expect(list().tasksNear().single.distanceKm, isNull, reason: '自己沒有定位時距離未知');
    });

    test('自己的廣播、不是 Health Report 的封包、解不開的內容都不列', () async {
      board.startCollecting();
      final list = await watch();

      await receive(_packet(_payload(handle: _myHandle)));
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb'), type: BlePacketType.message));
      await receive(_packet([0x02, 0x01]));
      await receive({'type': 'system_status', 'bluetoothEnabled': true});

      expect(list().tasksNear(), isEmpty);
    });

    test('同一個 Reporter Handle 較舊的回報晚到時，不蓋掉較新的', () async {
      board.startCollecting();
      final list = await watch();

      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000100)));
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb', status: 1, secs: 1700000000)));

      expect(list().tasksNear().single.injury, '重傷');
    });
  });

  group('任務進度', () {
    test('BLE 任務的進度只記在本機', () async {
      board.startCollecting();
      final list = await watch();
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb')));

      final result = await board.updateStatus(list().tasksNear().single, TaskStatus.accepted, currentUserId: 'me');
      await pumpEventQueue();

      expect(result, TaskUpdate.updated);
      expect(list().tasksNear().single.status, TaskStatus.accepted);
      expect(store.updates, isEmpty);
    });

    test('Firestore 任務寫回進度與 Helper；放棄時清掉 Helper', () async {
      final list = await watch();
      store.pushReports([_report('alice')]);
      await pumpEventQueue();
      final task = list().tasksNear(currentUserId: 'me').single;

      expect(await board.updateStatus(task, TaskStatus.accepted, currentUserId: 'me'), TaskUpdate.updated);
      expect(await board.updateStatus(task, TaskStatus.waiting, currentUserId: 'me'), TaskUpdate.updated);

      expect(store.updates, [
        (reportId: 'alice', status: TaskStatus.accepted, helperId: 'me'),
        (reportId: 'alice', status: TaskStatus.waiting, helperId: null),
      ]);
    });

    test('沒有帳號不能接 Firestore 任務，也不送出必定被擋的寫入', () async {
      final list = await watch();
      store.pushReports([_report('alice')]);
      await pumpEventQueue();

      final result = await board.updateStatus(
        list().tasksNear(currentUserId: 'me').single,
        TaskStatus.accepted,
        currentUserId: null,
      );

      expect(result, TaskUpdate.signInRequired);
      expect(store.updates, isEmpty);
    });

    test('寫入失敗時如實回報', () async {
      final list = await watch();
      store.pushReports([_report('alice')]);
      await pumpEventQueue();
      store.updateError = StateError('denied');

      expect(
        await board.updateStatus(
          list().tasksNear(currentUserId: 'me').single,
          TaskStatus.accepted,
          currentUserId: 'me',
        ),
        TaskUpdate.failed,
      );
    });
  });

  test('讀對方的 Sensitive Tier；讀不到時把錯誤交給畫面', () async {
    store.sensitive = {
      'alice': {'phone': '0912345678'},
    };
    expect(await board.readSensitive('alice'), {'phone': '0912345678'});

    store.sensitiveError = const TaskAccessDenied();
    await expectLater(board.readSensitive('alice'), throwsA(isA<TaskAccessDenied>()));
  });

  group('BLE 任務收到同一人較新的回報時，本機進度要不要回到等待中', () {
    /// 收到 [first]、把進度改成 [progress]，再收到 [next]，回傳任務最後的進度。
    Future<TaskStatus> progressAfter(List<int> first, TaskStatus progress, List<int> next) async {
      board.startCollecting();
      final list = await watch();
      await receive(_packet(first));
      await board.updateStatus(list().tasksNear().single, progress, currentUserId: 'me');
      await receive(_packet(next));
      return list().tasksNear().single.status;
    }

    test('已完成，對方又舉起 SOS：重新開一筆，不然這次求救沒人看得到', () async {
      expect(
        await progressAfter(
          _payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000000),
          TaskStatus.done,
          _payload(handle: 'bbbbbbbbbbbb', status: 2, sos: true, secs: 1700000100),
        ),
        TaskStatus.waiting,
      );
    });

    test('進行中，對方的 Status 改變：回到等待中', () async {
      expect(
        await progressAfter(
          _payload(handle: 'bbbbbbbbbbbb', status: 1, secs: 1700000000),
          TaskStatus.accepted,
          _payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000100),
        ),
        TaskStatus.waiting,
      );
    });

    test('進行中，對方重送相同的 Status：進度保留，路上的協助者不會丟掉任務', () async {
      expect(
        await progressAfter(
          _payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000000),
          TaskStatus.accepted,
          _payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000100),
        ),
        TaskStatus.accepted,
      );
    });

    test('已完成，對方送相同的 Status 而沒有 SOS：維持已完成', () async {
      expect(
        await progressAfter(
          _payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000000),
          TaskStatus.done,
          _payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000100),
        ),
        TaskStatus.done,
      );
    });

    test('較舊的回報晚到時不影響進度', () async {
      expect(
        await progressAfter(
          _payload(handle: 'bbbbbbbbbbbb', status: 2, secs: 1700000100),
          TaskStatus.done,
          _payload(handle: 'bbbbbbbbbbbb', status: 1, sos: true, secs: 1700000000),
        ),
        TaskStatus.done,
      );
    });
  });

  group('BLE 回報從 app 啟動就開始收，不必開著清單', () {
    test('關掉清單時照樣收，再打開時看得到', () async {
      board.startCollecting();
      final first = board.watch().listen((_) {});
      await pumpEventQueue();
      await first.cancel();

      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb')));
      final list = await watch();

      expect(list().tasksNear().single.userId, 'bbbbbbbbbbbb');
    });

    test('本機的進度在關掉清單後也留著', () async {
      board.startCollecting();
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb')));
      final first = await watch();
      await board.updateStatus(first().tasksNear().single, TaskStatus.accepted, currentUserId: 'me');

      final again = await watch();

      expect(again().tasksNear().single.status, TaskStatus.accepted);
    });

    test('登出或緊急清除時忘掉收到的回報與本機進度，之後照常收', () async {
      board.startCollecting();
      final list = await watch();
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb')));
      await board.updateStatus(list().tasksNear().single, TaskStatus.accepted, currentUserId: 'me');

      board.clear();
      await pumpEventQueue();
      expect(list().tasksNear(), isEmpty);

      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb')));
      expect(list().tasksNear().single.status, TaskStatus.waiting);
    });

    test('清除前收到、清除後才解碼完的回報不留下來', () async {
      final decoding = Completer<void>();
      board = MutualAidTaskBoard(
        store: store,
        events: () => events.stream,
        ownHandle: () async => _myHandle,
        decode: (bytes) async {
          await decoding.future;
          return HealthReportPayload.decode(bytes);
        },
      );
      board.startCollecting();
      final list = await watch();
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb')));

      board.clear();
      decoding.complete();
      await pumpEventQueue();

      expect(list().tasksNear(), isEmpty);
    });

    test('Reporter 太多時丟掉回報最舊的那位，連同本機進度', () async {
      board = MutualAidTaskBoard(
        store: store,
        events: () => events.stream,
        ownHandle: () async => _myHandle,
        decode: (bytes) async => HealthReportPayload.decode(bytes),
        bleCapacity: 2,
      );
      board.startCollecting();
      final list = await watch();
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb', secs: 1700000000)));
      await board.updateStatus(list().tasksNear().single, TaskStatus.accepted, currentUserId: 'me');
      await receive(_packet(_payload(handle: 'cccccccccccc', secs: 1700000200)));

      await receive(_packet(_payload(handle: 'dddddddddddd', secs: 1700000100)));

      expect(list().tasksNear().map((t) => t.userId).toSet(), {'cccccccccccc', 'dddddddddddd'});
      await receive(_packet(_payload(handle: 'bbbbbbbbbbbb', secs: 1700000300)));
      expect(list().tasksNear().firstWhere((t) => t.userId == 'bbbbbbbbbbbb').status, TaskStatus.waiting);
    });
  });
}
