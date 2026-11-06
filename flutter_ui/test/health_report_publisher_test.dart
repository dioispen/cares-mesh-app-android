import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart';
import 'package:flutter_ui/models/health_survey.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/services/health_report_publisher.dart';
import 'package:flutter_ui/services/own_report_cache.dart';
import 'package:flutter_ui/services/sos.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_health_report_store.dart';

final _user = AppUser(
  id: 'alice',
  name: 'Alice',
  phone: '0912345678',
  area: '台北市中正區',
  emergencyContactName: '王大明',
  emergencyContactPhone: '0987654321',
  emergencyContactRelation: '父親',
  registeredAt: DateTime(2024),
);

/// 一份交給 mesh 的 Broadcast Tier。
typedef _Broadcast = ({String handle, String status, double? lat, double? lng, bool sos});

void main() {
  late InMemoryHealthReportStore store;
  late List<_Broadcast> broadcasts;
  late HealthReportPublisher publisher;

  /// 下一次交給 mesh 時拋出的錯誤；null 表示送出成功。
  Object? broadcastError;

  /// 依序卡住接下來的廣播，直到測試放行；用來重現先發動的動作晚完成。
  late List<Completer<void>> broadcastGates;

  HealthReportPublisher newPublisher() => HealthReportPublisher(
    store: store,
    // 離線的寫入不會完成；測試不必真的等 8 秒。
    uploadTimeout: const Duration(milliseconds: 20),
    broadcast:
        ({
          required String reporterHandle,
          required String status,
          required double? lat,
          required double? lng,
          required bool sos,
        }) async {
          final error = broadcastError;
          if (error != null) throw error;
          if (broadcastGates.isNotEmpty) await broadcastGates.removeAt(0).future;
          broadcasts.add((handle: reporterHandle, status: status, lat: lat, lng: lng, sos: sos));
        },
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = InMemoryHealthReportStore();
    broadcasts = [];
    broadcastError = null;
    broadcastGates = [];
    publisher = newPublisher();
  });

  group('任務要不要回到等待中', () {
    test('調查表一併舉起 SOS、Status 沒變，已完成的任務重新開一筆', () async {
      store.detail = {'status': '重傷', 'description': null, 'taskStatus': 'done', 'helperId': 'bob'};

      await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey(), raiseSos: true);

      expect(store.detail['sos'], isTrue);
      expect(store.detail['taskStatus'], 'waiting');
      expect(store.detail['helperId'], isNull);
    });

    test('調查的 Status 改變，任務回到等待中', () async {
      store.detail = {'status': '輕傷', 'taskStatus': 'accepted', 'helperId': 'bob'};

      await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey());

      expect(store.detail['taskStatus'], 'waiting');
      expect(store.detail['helperId'], isNull);
    });

    test('調查的傷勢細項改變，任務回到等待中', () async {
      store.detail = {'status': '輕傷', 'description': '割傷', 'taskStatus': 'accepted', 'helperId': 'bob'};

      await publisher.submitSurvey(
        _user,
        status: '輕傷',
        survey: const HealthSurvey(injuries: ['骨折']),
      );

      expect(store.detail['taskStatus'], 'waiting');
      expect(store.detail['helperId'], isNull);
      expect(store.detail['description'], '骨折');
    });

    test('重送相同內容，路上的協助者不會丟掉任務', () async {
      store.detail = {'status': '輕傷', 'description': null, 'taskStatus': 'accepted', 'helperId': 'bob'};

      await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      expect(store.detail['taskStatus'], 'accepted');
      expect(store.detail['helperId'], 'bob');
    });

    test('舉起 SOS、Status 沒變，協助者的認領不受影響', () async {
      store.detail = {'status': '重傷', 'description': '骨折', 'taskStatus': 'accepted', 'helperId': 'bob'};
      await OwnStatusCache.save('alice', '重傷', '骨折');

      await publisher.raiseSos(_user);

      expect(store.detail['sos'], isTrue);
      expect(store.detail['taskStatus'], 'accepted');
      expect(store.detail['helperId'], 'bob');
      expect(store.detail['description'], '骨折');
    });

    test('已完成的任務又舉起 SOS，重新開一筆', () async {
      store.detail = {'status': '重傷', 'taskStatus': 'done', 'helperId': 'bob'};
      await OwnStatusCache.save('alice', '重傷', null);

      await publisher.raiseSos(_user);

      expect(store.detail['taskStatus'], 'waiting');
      expect(store.detail['helperId'], isNull);
    });

    test('SOS 還舉著，Reporter 更新調查時已完成的任務也重新開一筆', () async {
      await publisher.raiseSos(_user);
      store.detail = {...store.detail, 'status': '重傷', 'description': null, 'taskStatus': 'done', 'helperId': 'bob'};

      await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey());

      expect(store.detail['sos'], isTrue);
      expect(store.detail['taskStatus'], 'waiting');
    });

    test('讀不到文件時用本機記得的 Status 判斷；不知道任務狀態，所以不重開', () async {
      await OwnStatusCache.save('alice', '重傷', null);
      store.unreadable = true;
      store.detail = {'taskStatus': 'done', 'helperId': 'bob'};

      await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey(), raiseSos: true);

      expect(store.detail['taskStatus'], 'done');
      expect(store.detail['helperId'], 'bob');
    });

    test('讀不到文件、本機記得的 Status 也不同時，任務回到等待中', () async {
      await OwnStatusCache.save('alice', '輕傷', null);
      store.unreadable = true;
      store.detail = {'taskStatus': 'accepted', 'helperId': 'bob'};

      await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey());

      expect(store.detail['taskStatus'], 'waiting');
    });
  });

  group('廣播與雲端兩條路互不影響', () {
    final meshDown = PlatformException(code: HealthReportErrors.serviceNotReady);

    test('都送到：Status 與 SOS 記下來', () async {
      final sent = await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey(), raiseSos: true);

      expect(sent.delivery.complete, isTrue);
      expect(sent.raisedNow, isTrue);
      expect(sent.sos.raised, isTrue);
      expect((await OwnStatusCache.load('alice')).status, '重傷');
      expect((await SosStore.load('alice')).raised, isTrue);
    });

    test('廣播失敗仍然上傳，也算回報過', () async {
      broadcastError = meshDown;

      final sent = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      expect(sent.delivery.broadcastFailure, 'mesh 尚未啟動');
      expect(sent.delivery.failed, isFalse);
      expect(store.detail['status'], '輕傷');
      expect((await OwnStatusCache.load('alice')).status, '輕傷');
    });

    test('上傳失敗仍然廣播，也算回報過', () async {
      store.writeError = StateError('denied');

      final sent = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      expect(sent.delivery.uploadFailure, contains('denied'));
      expect(sent.delivery.failed, isFalse);
      expect(broadcasts.single.status, '輕傷');
      expect((await OwnStatusCache.load('alice')).status, '輕傷');
    });

    test('兩條路都失敗：誰都沒收到，Status 與 SOS 都不記', () async {
      broadcastError = meshDown;
      store.writeError = StateError('denied');

      final sent = await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey(), raiseSos: true);

      expect(sent.delivery.failed, isTrue);
      expect((await OwnStatusCache.load('alice')).status, isNull);
      expect((await SosStore.load('alice')).raised, isFalse);
    });

    test('沒有定位時如實記下，座標不寫假值', () async {
      final sent = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      expect(sent.delivery.withLocation, isFalse);
      expect(broadcasts.single.lat, isNull);
      expect(store.detail['lat'], isNull);
    });
  });

  group('離線暫存的上傳', () {
    test('逾時算暫存，不是失敗；之後送到時回報完成', () async {
      store.holdAcks = true;

      final sent = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      expect(sent.delivery.uploadQueued, isTrue);
      expect(sent.delivery.failed, isFalse);
      store.releaseAcks();
      final settled = await sent.queuedUpload!;
      expect(settled.uploadQueued, isFalse);
      expect(settled.uploadFailure, isNull);
    });

    test('之後才失敗時要回報原因，不只是留在 log', () async {
      store.holdAcks = true;

      final sent = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      store.releaseAcks(error: StateError('denied'));
      final settled = await sent.queuedUpload!;
      expect(settled.uploadQueued, isFalse);
      expect(settled.uploadFailure, contains('denied'));
    });

    test('沒有暫存時不必追蹤', () async {
      final sent = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      expect(sent.queuedUpload, isNull);
    });
  });

  group('SOS 的動作（ADR-0004）', () {
    test('從未回報過就舉起：Status 是未宣告，附近與雲端都帶 SOS', () async {
      final sent = await publisher.raiseSos(_user, lat: 25.0, lng: 121.5);

      expect(sent.status, '未宣告');
      expect(sent.raisedNow, isTrue);
      expect(sent.sos.raised, isTrue);
      expect(sent.delivery.withLocation, isTrue);
      expect(broadcasts.single.status, '未宣告');
      expect(broadcasts.single.sos, isTrue);
      expect(store.detail['status'], '未宣告');
      expect(store.detail['sos'], isTrue);
      expect(store.detail['lat'], 25.0);
      expect((await SosStore.load('alice')).raised, isTrue);
    });

    test('沿用最近一次的傷勢；Status 沒變時傷勢細項也留著', () async {
      await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey());
      await OwnStatusCache.save('alice', '重傷', '骨折');

      final sent = await publisher.raiseSos(_user);

      expect(sent.status, '重傷');
      expect((await OwnStatusCache.load('alice')).subInjury, '骨折');
    });

    test('Status 改成未宣告時，本機記得的傷勢細項清掉', () async {
      await OwnStatusCache.save('alice', '安全', '舊的');

      await publisher.raiseSos(_user);

      expect(await OwnStatusCache.load('alice'), (status: '未宣告', subInjury: null));
    });

    test('沒有位置時不把雲端先前回報的真實位置抹掉', () async {
      store.detail = {'status': '未宣告', 'lat': 25.0, 'lng': 121.5};

      final sent = await publisher.raiseSos(_user);

      expect(sent.delivery.withLocation, isFalse);
      expect(store.detail['lat'], 25.0);
    });

    test('寫 Sensitive Tier 時保留健康回報填過的調查（ADR-0007）', () async {
      store.sensitive = {
        'surveySensitive': {'notes': '家中有長者'},
      };

      await publisher.raiseSos(_user);

      expect(store.sensitive['surveySensitive'], {'notes': '家中有長者'});
      expect(store.sensitive['phone'], '0912345678');
    });

    test('健康回報整份寫入 Sensitive Tier，包含這次的調查', () async {
      store.sensitive = {'stale': true};

      await publisher.submitSurvey(
        _user,
        status: '輕傷',
        survey: const HealthSurvey(notes: '需要輪椅'),
      );

      expect(store.sensitive.keys, isNot(contains('stale')));
      expect((store.sensitive['surveySensitive'] as Map)['notes'], '需要輪椅');
    });

    test('舉著 SOS 時回報傷勢仍帶著 SOS；回報安全就是撤回', () async {
      await publisher.raiseSos(_user);

      final injured = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());
      expect(broadcasts.last.sos, isTrue);
      expect(injured.sos.raised, isTrue);

      final safe = await publisher.submitSurvey(_user, status: '安全', survey: const HealthSurvey());
      expect(broadcasts.last.sos, isFalse);
      expect(safe.sos.raised, isFalse);
      expect((await SosStore.load('alice')).raised, isFalse);
    });

    test('撤回就是回報安全、不帶 SOS', () async {
      await publisher.raiseSos(_user);

      final sent = await publisher.withdrawSos(_user);

      expect(sent.status, '安全');
      expect(sent.sos.raised, isFalse);
      expect(broadcasts.last.status, '安全');
      expect(broadcasts.last.sos, isFalse);
      expect(store.detail['sos'], isFalse);
    });

    test('撤回沒有人收到時 SOS 仍在', () async {
      await publisher.raiseSos(_user);
      broadcastError = StateError('mesh');
      store.writeError = StateError('denied');

      final sent = await publisher.withdrawSos(_user);

      expect(sent.delivery.failed, isTrue);
      expect(sent.sos.raised, isTrue);
      expect((await SosStore.load('alice')).raised, isTrue);
    });

    test('補位置：舉起的時間不變，雲端只改位置，認領不受影響', () async {
      final raised = await publisher.raiseSos(_user);
      store.detail = {...store.detail, 'taskStatus': 'accepted', 'helperId': 'bob'};

      final located = await publisher.addSosLocation(_user, lat: 25.0, lng: 121.5);

      expect(located.raisedNow, isFalse);
      expect(located.sos.raisedAt!.isAtSameMomentAs(raised.sos.raisedAt!), isTrue);
      expect(broadcasts.last.sos, isTrue);
      expect(broadcasts.last.lat, 25.0);
      expect(store.detail['lat'], 25.0);
      expect(store.detail['helperId'], 'bob');
    });
  });

  group('同時發生的動作：以後發動的為準', () {
    test('調查還沒完成就舉起 SOS：調查晚完成也不會蓋掉 SOS', () async {
      final surveyBroadcast = Completer<void>();
      broadcastGates.add(surveyBroadcast);
      final survey = publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());
      await pumpEventQueue();

      final raised = await publisher.raiseSos(_user);
      surveyBroadcast.complete();
      final surveyed = await survey;

      expect(raised.sos.raised, isTrue);
      expect(raised.status, '輕傷', reason: '舉起時沿用還在送出的那份 Status');
      expect(surveyed.sos.raised, isTrue, reason: '畫面不能顯示 SOS 已放下');
      expect((await SosStore.load('alice')).raised, isTrue);
      expect((await OwnStatusCache.load('alice')).status, '輕傷');
    });

    test('SOS 還沒完成就送調查：調查帶著這個 SOS', () async {
      final sosBroadcast = Completer<void>();
      broadcastGates.add(sosBroadcast);
      final raising = publisher.raiseSos(_user);
      await pumpEventQueue();

      final surveyed = await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey());
      sosBroadcast.complete();
      await raising;

      expect(broadcasts.firstWhere((b) => b.status == '重傷').sos, isTrue);
      expect(store.detail['sos'], isTrue);
      expect(surveyed.sos.raised, isTrue);
      expect((await SosStore.load('alice')).raised, isTrue);
      expect((await OwnStatusCache.load('alice')).status, '重傷');
    });

    test('雲端照發動順序寫入；廣播不等前一個動作的雲端', () async {
      store.holdReads = true;
      final first = publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());
      await pumpEventQueue();
      store.holdReads = false;

      final second = publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey());
      await pumpEventQueue();
      expect(broadcasts.map((b) => b.status), contains('重傷'));
      expect(store.detailWrites, isEmpty);

      store.releaseReads();
      await first;
      await second;
      await pumpEventQueue();

      expect(store.detailWrites.map((w) => w['status']), ['輕傷', '重傷']);
      expect(store.detail['status'], '重傷');
    });

    test('先發動的動作沒有人收到，不影響後發動的動作', () async {
      broadcastError = StateError('mesh');
      store.writeError = StateError('denied');
      final failed = await publisher.raiseSos(_user);
      broadcastError = null;
      store.writeError = null;

      final surveyed = await publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey());

      expect(failed.sos.raised, isFalse);
      expect(surveyed.sos.raised, isFalse);
      expect(broadcasts.single.sos, isFalse);
    });

    test('本機狀態讀到的是還在送出中的那一份', () async {
      final sosBroadcast = Completer<void>();
      broadcastGates.add(sosBroadcast);
      final raising = publisher.raiseSos(_user);
      await pumpEventQueue();

      expect((await publisher.sosState('alice')).raised, isTrue);

      sosBroadcast.complete();
      await raising;
      expect((await publisher.sosState('alice')).raised, isTrue);
      expect(await publisher.lastStatus('alice'), (status: '未宣告', subInjury: null));
    });

    test('各帳號的 SOS 分開', () async {
      await publisher.raiseSos(_user);

      expect((await publisher.sosState('someone-else')).raised, isFalse);
    });
  });

  group('Reporter Handle', () {
    test('同時發動的第一次動作共用同一個 Handle，之後也不變', () async {
      await Future.wait([
        publisher.submitSurvey(_user, status: '輕傷', survey: const HealthSurvey()),
        publisher.raiseSos(_user),
      ]);

      expect(broadcasts.map((b) => b.handle).toSet(), hasLength(1));
      expect(await publisher.reporterHandle(), broadcasts.first.handle);
      expect(broadcasts.first.handle, matches(RegExp(r'^[0-9a-f]{12}$')));
    });

    test('廣播只帶 Broadcast Tier 需要的欄位，已存的 Handle 不換', () async {
      SharedPreferences.setMockInitialValues({'broadcast_handle': 'abcdef012345'});
      final existing = newPublisher();

      await existing.raiseSos(_user, lat: 25.0, lng: 121.5);

      expect(broadcasts.single, (handle: 'abcdef012345', status: '未宣告', lat: 25.0, lng: 121.5, sos: true));
    });
  });

  group('自己的回報以後端為準', () {
    Future<List<OwnReport>> collect(void Function() act) async {
      final seen = <OwnReport>[];
      final subscription = publisher.watchOwnReport('alice').listen(seen.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      act();
      await pumpEventQueue();
      return seen;
    }

    Map<String, dynamic> doc({String status = '輕傷', String? description, Map<String, dynamic>? survey}) => {
      'reporterId': 'alice',
      'status': status,
      'description': description,
      'survey': survey,
    };

    test('兩份文件的調查併成一份，傷勢細項也記下來', () async {
      store.sensitive = {
        'surveySensitive': {'notes': '家中有長者'},
      };

      final seen = await collect(() => store.pushDetailSnapshot(doc(description: '割傷', survey: {'mobility': '可自行行動'})));

      expect(seen.last.status, '輕傷');
      expect(seen.last.subInjury, '割傷');
      expect(seen.last.survey.mobility, '可自行行動');
      expect(seen.last.survey.notes, '家中有長者');
      expect(await OwnStatusCache.load('alice'), (status: '輕傷', subInjury: '割傷'));
    });

    test('Sensitive Tier 比較晚讀到時，再補一次完整的調查', () async {
      store.holdSensitiveRead = true;
      store.sensitive = {
        'surveySensitive': {'notes': '家中有長者'},
      };

      final seen = await collect(() => store.pushDetailSnapshot(doc(survey: {'mobility': '可自行行動'})));
      expect(seen.last.survey.notes, '');

      store.releaseSensitiveRead();
      await pumpEventQueue();

      expect(seen.last.survey.mobility, '可自行行動');
      expect(seen.last.survey.notes, '家中有長者');
    });

    test('讀不到 Sensitive Tier 也照樣顯示 Detail Tier', () async {
      store.unreadable = true;

      final seen = await collect(() => store.pushDetailSnapshot(doc()));

      expect(seen.last.status, '輕傷');
      expect(seen.last.survey.notes, '');
    });

    test('文件的 reporterId 不是自己就不當成自己的狀態', () async {
      final seen = await collect(() => store.pushDetailSnapshot({...doc(), 'reporterId': 'mallory'}));

      expect(seen, isEmpty);
      expect((await OwnStatusCache.load('alice')).status, isNull);
    });

    test('後端沒有文件時不動本機記得的狀態', () async {
      await OwnStatusCache.save('alice', '重傷', null);

      final seen = await collect(() => store.pushDetailSnapshot(null));

      expect(seen, isEmpty);
      expect((await OwnStatusCache.load('alice')).status, '重傷');
    });

    test('剛送出的調查，之後的更新要併入這次的 Sensitive Tier', () async {
      final seen = await collect(() {});

      await publisher.submitSurvey(
        _user,
        status: '輕傷',
        survey: const HealthSurvey(notes: '需要輪椅'),
      );
      store.pushDetailSnapshot(doc());
      await pumpEventQueue();

      expect(seen.last.survey.notes, '需要輪椅');
    });

    test('送調查時 Sensitive Tier 還沒讀回來，舊內容不能蓋掉這次的', () async {
      store.holdSensitiveRead = true;
      store.sensitive = {
        'surveySensitive': {'notes': '舊的'},
      };
      final seen = await collect(() {});

      await publisher.submitSurvey(
        _user,
        status: '輕傷',
        survey: const HealthSurvey(notes: '新的'),
      );
      store.pushDetailSnapshot(doc());
      store.releaseSensitiveRead();
      await pumpEventQueue();

      expect(seen.last.survey.notes, '新的');
    });

    test('監聽出錯不會中斷，之後的更新照常收到', () async {
      final seen = await collect(() => store.pushDetailError(StateError('offline')));

      store.pushDetailSnapshot(doc());
      await pumpEventQueue();

      expect(seen.single.status, '輕傷');
    });

    test('取消之後不再監聽', () async {
      final subscription = publisher.watchOwnReport('alice').listen((_) {});
      await pumpEventQueue();
      expect(store.hasDetailListener, isTrue);

      await subscription.cancel();

      expect(store.hasDetailListener, isFalse);
    });
  });

  group('寫入的欄位都在 firestore.rules 允許的範圍內：多一個欄位，規則就會擋下整筆回報', () {
    final rules = File('../firestore.rules').readAsStringSync();

    /// 規則裡 `[...]` 列出的欄位。
    Set<String> listedAfter(String marker) {
      final start = rules.indexOf(marker);
      if (start < 0) throw StateError('firestore.rules 找不到 $marker');
      final list = RegExp(r'\[([^\]]*)\]').firstMatch(rules.substring(start))!.group(1)!;
      return RegExp(r"'(\w+)'").allMatches(list).map((m) => m.group(1)!).toSet();
    }

    final detailKeys = listedAfter('function detailTierKeys()');
    final sensitiveKeys = listedAfter("match /health_report_sensitive/{uid}");
    final detailSurveyKeys = listedAfter('function detailSurveyKeys()');
    final sensitiveSurveyKeys = listedAfter('function sensitiveSurveyKeys()');

    test('規則解析得到內容，不是空清單', () {
      expect(detailKeys, containsAll(['reporterId', 'status', 'sos', 'survey', 'taskStatus', 'helperId']));
      expect(sensitiveKeys, containsAll(['reporterId', 'phone', 'surveySensitive']));
    });

    test('送調查', () async {
      await publisher.submitSurvey(_user, status: '重傷', survey: const HealthSurvey(), lat: 25.0, lng: 121.5);

      expect(store.detail.keys.toSet().difference(detailKeys), isEmpty);
      expect(store.sensitive.keys.toSet().difference(sensitiveKeys), isEmpty);
      expect((store.detail['survey'] as Map).keys.toSet().difference(detailSurveyKeys), isEmpty);
      expect((store.sensitive['surveySensitive'] as Map).keys.toSet().difference(sensitiveSurveyKeys), isEmpty);
    });

    test('舉起與撤回 SOS', () async {
      await publisher.raiseSos(_user, lat: 25.0, lng: 121.5);
      expect(store.detail.keys.toSet().difference(detailKeys), isEmpty);
      expect(store.sensitive.keys.toSet().difference(sensitiveKeys), isEmpty);

      await publisher.withdrawSos(_user);
      expect(store.detail.keys.toSet().difference(detailKeys), isEmpty);
    });
  });
}
