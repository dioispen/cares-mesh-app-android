import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/mutual_aid_tasks.dart';

/// 台北車站附近的三個點，用來驗證「近的排前面」。
const _taipeiMainStation = (lat: 25.0478, lng: 121.5170);
const _about1km = (lat: 25.0568, lng: 121.5170);
const _about5km = (lat: 25.0928, lng: 121.5170);

ReportEntry _report({
  required String id,
  String? reporterId,
  String status = '輕傷',
  String? name = '小明',
  String? description = '割傷',
  double? lat,
  double? lng,
  String? taskStatus,
  String? helperId,
}) =>
    (
      id: id,
      data: <String, dynamic>{
        'reporterId': reporterId ?? id,
        'name': name,
        'status': status,
        'description': description,
        'lat': lat,
        'lng': lng,
        'taskStatus': ?taskStatus,
        'helperId': ?helperId,
      },
    );

MutualAidTask _bleTask({
  required String handle,
  String injury = '重傷',
  double? distanceKm,
}) =>
    MutualAidTask(
      id: 'ble_$handle',
      name: '匿名回報 ${handle.substring(0, 4)}',
      userId: handle,
      injury: injury,
      location: '概略位置',
      distanceKm: distanceKm,
      note: '來自 BLE 廣播',
      isBle: true,
    );

void main() {
  group('buildMutualAidTasks', () {
    test('排除自己的回報：自己的狀態不該出現在待救援清單', () {
      final tasks = buildMutualAidTasks(
        reports: [
          _report(id: 'me'),
          _report(id: 'other'),
        ],
        bleTasks: const [],
        currentUserId: 'me',
        myLat: null,
        myLng: null,
      );

      expect(tasks.map((t) => t.userId), ['other']);
    });

    test('還不知道自己是誰時不顯示任何 Firestore 任務，避免閃出自己那筆', () {
      final tasks = buildMutualAidTasks(
        reports: [_report(id: 'someone')],
        bleTasks: const [],
        currentUserId: null,
        myLat: null,
        myLng: null,
      );

      expect(tasks, isEmpty);
    });

    test('只有輕傷／重傷是任務，安全或未知狀態一律排除', () {
      final tasks = buildMutualAidTasks(
        reports: [
          _report(id: 'a', status: '安全'),
          _report(id: 'b', status: '輕傷'),
          _report(id: 'c', status: '重傷'),
          _report(id: 'd', status: '尚未回報'),
        ],
        bleTasks: const [],
        currentUserId: 'me',
        myLat: null,
        myLng: null,
      );

      expect(tasks.map((t) => t.userId), ['b', 'c']);
    });

    test('近的排前面，距離未知的排最後而不是當成 0 公里', () {
      final tasks = buildMutualAidTasks(
        reports: [
          _report(id: 'far', lat: _about5km.lat, lng: _about5km.lng),
          _report(id: 'unknown'),
          _report(id: 'near', lat: _about1km.lat, lng: _about1km.lng),
        ],
        bleTasks: const [],
        currentUserId: 'me',
        myLat: _taipeiMainStation.lat,
        myLng: _taipeiMainStation.lng,
      );

      expect(tasks.map((t) => t.userId), ['near', 'far', 'unknown']);
      expect(tasks.last.distanceKm, isNull);
      expect(tasks.last.distanceLabel, '距離未知');
      expect(tasks.first.distanceKm, closeTo(1.0, 0.2));
      expect(tasks.first.distanceLabel, '1.0 km');
    });

    test('自己沒有定位時所有距離都是未知，不會謊報 0 公里', () {
      final tasks = buildMutualAidTasks(
        reports: [_report(id: 'other', lat: _about1km.lat, lng: _about1km.lng)],
        bleTasks: const [],
        currentUserId: 'me',
        myLat: null,
        myLng: null,
      );

      expect(tasks.single.distanceKm, isNull);
      expect(tasks.single.distanceLabel, '距離未知');
    });

    test('帶回 taskStatus 與 helperId，欄位缺席時當成等待中／無人認領', () {
      final tasks = buildMutualAidTasks(
        reports: [
          _report(id: 'accepted', taskStatus: 'accepted', helperId: 'helper-1'),
          _report(id: 'done', taskStatus: 'done', helperId: 'helper-2'),
          _report(id: 'legacy'),
          _report(id: 'junk', taskStatus: '???'),
        ],
        bleTasks: const [],
        currentUserId: 'me',
        myLat: null,
        myLng: null,
      );

      final byId = {for (final t in tasks) t.userId: t};
      expect(byId['accepted']!.status, TaskStatus.accepted);
      expect(byId['accepted']!.helperId, 'helper-1');
      expect(byId['done']!.status, TaskStatus.done);
      expect(byId['legacy']!.status, TaskStatus.waiting);
      expect(byId['legacy']!.helperId, isNull);
      expect(byId['junk']!.status, TaskStatus.waiting);
    });

    test('缺欄位或空字串的文件不會炸掉，顯示可讀的預設值', () {
      final tasks = buildMutualAidTasks(
        reports: [
          (
            id: 'sparse',
            data: <String, dynamic>{'reporterId': 'sparse', 'status': '重傷'},
          ),
          _report(id: 'blank', name: '  ', description: ''),
          // 沒有 reporterId 的髒資料無法判斷是誰的，直接略過。
          (id: 'orphan', data: <String, dynamic>{'status': '輕傷'}),
        ],
        bleTasks: const [],
        currentUserId: 'me',
        myLat: _taipeiMainStation.lat,
        myLng: _taipeiMainStation.lng,
      );

      expect(tasks.map((t) => t.userId), containsAll(['sparse', 'blank']));
      expect(tasks.any((t) => t.userId == 'orphan'), isFalse);
      final sparse = tasks.firstWhere((t) => t.userId == 'sparse');
      expect(sparse.name, '未知');
      expect(sparse.location, '位置未提供');
      expect(sparse.note, '無補充說明');
      final blank = tasks.firstWhere((t) => t.userId == 'blank');
      expect(blank.name, '未知');
      expect(blank.note, '無補充說明');
    });

    test('帶回對方的座標，沒有位置的回報是 null（導航按鈕據此決定能不能按）', () {
      final tasks = buildMutualAidTasks(
        reports: [
          _report(id: 'located', lat: _about1km.lat, lng: _about1km.lng),
          _report(id: 'nowhere'),
        ],
        bleTasks: const [],
        currentUserId: 'me',
        myLat: _taipeiMainStation.lat,
        myLng: _taipeiMainStation.lng,
      );

      final located = tasks.firstWhere((t) => t.userId == 'located');
      expect(located.lat, _about1km.lat);
      expect(located.lng, _about1km.lng);
      final nowhere = tasks.firstWhere((t) => t.userId == 'nowhere');
      expect(nowhere.lat, isNull);
      expect(nowhere.lng, isNull);
    });

    test('BLE 任務：安全狀態不列入，並套用本機的接任務進度', () {
      final tasks = buildMutualAidTasks(
        reports: const [],
        bleTasks: [
          _bleTask(handle: 'aaaaaaaaaaaa'),
          _bleTask(handle: 'bbbbbbbbbbbb', injury: '安全'),
        ],
        currentUserId: 'me',
        myLat: null,
        myLng: null,
        bleStatusOverrides: const {'ble_aaaaaaaaaaaa': TaskStatus.accepted},
      );

      expect(tasks.single.userId, 'aaaaaaaaaaaa');
      expect(tasks.single.status, TaskStatus.accepted);
      expect(tasks.single.isBle, isTrue);
    });

    test('同一個 handle 已有 Firestore 任務時以 Firestore 為主，不重複列出', () {
      final tasks = buildMutualAidTasks(
        reports: [_report(id: 'aaaaaaaaaaaa', status: '重傷')],
        bleTasks: [_bleTask(handle: 'aaaaaaaaaaaa')],
        currentUserId: 'me',
        myLat: null,
        myLng: null,
      );

      expect(tasks, hasLength(1));
      expect(tasks.single.isBle, isFalse);
    });

    test('組任務不會就地改動傳進來的 BLE 任務物件', () {
      final ble = _bleTask(handle: 'cccccccccccc');
      buildMutualAidTasks(
        reports: const [],
        bleTasks: [ble],
        currentUserId: 'me',
        myLat: null,
        myLng: null,
        bleStatusOverrides: const {'ble_cccccccccccc': TaskStatus.done},
      );

      expect(ble.status, TaskStatus.waiting);
    });
  });

  group('navigationUris', () {
    test('iOS 先開原生地圖，再退到 Google Maps 網頁', () {
      final uris = navigationUris(
        lat: 25.0478,
        lng: 121.5170,
        platform: TargetPlatform.iOS,
        label: '小明',
      );

      expect(uris, hasLength(2));
      expect(uris.first.scheme, 'maps');
      expect(uris.first.toString(), contains('daddr=25.0478,121.517'));
      expect(uris.last.host, 'www.google.com');
      expect(uris.last.toString(), contains('destination=25.0478,121.517'));
    });

    test('Android 用 geo: scheme，名稱有跳脫', () {
      final uris = navigationUris(
        lat: 25.0478,
        lng: 121.5170,
        platform: TargetPlatform.android,
        label: '小 明',
      );

      expect(uris.first.scheme, 'geo');
      expect(uris.first.toString(), startsWith('geo:25.0478,121.517'));
      expect(uris.first.toString(), contains('%E5%B0%8F%20%E6%98%8E'));
      expect(uris.last.host, 'www.google.com');
    });

    test('其他平台只有網頁版', () {
      final uris = navigationUris(
        lat: 25.0478,
        lng: 121.5170,
        platform: TargetPlatform.macOS,
      );

      expect(uris, hasLength(1));
      expect(uris.single.host, 'www.google.com');
    });

    test('沒有名稱時不會產生空的括號', () {
      final uris = navigationUris(
        lat: 25.0,
        lng: 121.5,
        platform: TargetPlatform.android,
        label: '   ',
      );

      expect(uris.first.toString(), isNot(contains('()')));
    });
  });

  group('distanceKmBetween', () {
    test('任一端缺座標就回 null', () {
      expect(distanceKmBetween(null, 121.5, 25.0, 121.5), isNull);
      expect(distanceKmBetween(25.0, null, 25.0, 121.5), isNull);
      expect(distanceKmBetween(25.0, 121.5, null, 121.5), isNull);
      expect(distanceKmBetween(25.0, 121.5, 25.0, null), isNull);
    });

    test('兩端都有座標時回公里數', () {
      final km = distanceKmBetween(
        _taipeiMainStation.lat,
        _taipeiMainStation.lng,
        _about5km.lat,
        _about5km.lng,
      );
      expect(km, closeTo(5.0, 0.3));
    });
  });
}
