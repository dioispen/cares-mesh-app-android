import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/services/sos.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t1 = DateTime.utc(2026, 10, 22, 9, 30);
  final t2 = DateTime.utc(2026, 10, 22, 9, 45);

  group('sosStatusFor：舉起 SOS 時送出的 Status', () {
    test('從未回報過 → 未宣告', () => expect(sosStatusFor(null), '未宣告'));
    test('最近一次是安全 → 未宣告', () => expect(sosStatusFor('安全'), '未宣告'));
    test('輕傷沿用', () => expect(sosStatusFor('輕傷'), '輕傷'));
    test('重傷沿用', () => expect(sosStatusFor('重傷'), '重傷'));
    test('已經是未宣告 → 未宣告', () => expect(sosStatusFor('未宣告'), '未宣告'));
  });

  group('SOS 的狀態轉移', () {
    test('舉起：記下時間，送出帶 SOS 的回報', () {
      final t = raiseSos(const SosState.lowered(), lastStatus: null, now: t1);

      expect(t.state.raisedAt, t1);
      expect(t.report, (status: '未宣告', sos: true));
    });

    test('已經舉著再按一次：舉起的時間不變', () {
      final t = raiseSos(SosState.raisedAt(t1), lastStatus: '重傷', now: t2);

      expect(t.state.raisedAt, t1);
      expect(t.report, (status: '重傷', sos: true));
    });

    test('舉起期間回報輕傷：仍帶 SOS，SOS 沒有消失', () {
      final t = reportStatus(SosState.raisedAt(t1), '輕傷');

      expect(t.state.raised, isTrue);
      expect(t.report, (status: '輕傷', sos: true));
    });

    test('回報安全＝撤回 SOS', () {
      final t = reportStatus(SosState.raisedAt(t1), '安全');

      expect(t.state.raised, isFalse);
      expect(t.report, (status: '安全', sos: false));
    });

    test('沒有舉著時回報傷勢不帶 SOS', () {
      final t = reportStatus(const SosState.lowered(), '重傷');

      expect(t.state.raised, isFalse);
      expect(t.report, (status: '重傷', sos: false));
    });

    test('撤回 SOS＝回報安全：送出安全、不帶 SOS，SOS 放下', () {
      final t = withdrawSos();

      expect(t.report, (status: '安全', sos: false));
      expect(t.state.raised, isFalse);
    });
  });

  group('healthReportTransition：Health 畫面送出時一併舉起 SOS', () {
    test('選了舉起：記下舉起時間，回報照原本的 Status 帶 SOS', () {
      final t = healthReportTransition(const SosState.lowered(), '重傷', raise: true, now: t1);

      expect(t.state.raisedAt, t1);
      expect(t.report, (status: '重傷', sos: true));
    });

    test('沒選舉起：與一般回報相同', () {
      expect(
        healthReportTransition(const SosState.lowered(), '重傷', raise: false, now: t1).report,
        (status: '重傷', sos: false),
      );
      expect(
        healthReportTransition(SosState.raisedAt(t1), '重傷', raise: false, now: t2).report,
        (status: '重傷', sos: true),
      );
    });

    test('只有受傷時才能一併舉起：安全不能帶 SOS', () {
      expect(() => healthReportTransition(const SosState.lowered(), '安全', raise: true, now: t1), throwsArgumentError);
    });
  });

  group('SosStore：重啟後狀態保留，各帳號分開', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('存了再讀回來是同一個時間點', () async {
      await SosStore.save('alice', SosState.raisedAt(t1));

      expect((await SosStore.load('alice')).raisedAt, t1);
    });

    test('換帳號不會繼承前一個人的 SOS', () async {
      await SosStore.save('alice', SosState.raisedAt(t1));

      expect((await SosStore.load('bob')).raised, isFalse);
    });

    test('放下之後讀回來是沒有舉著', () async {
      await SosStore.save('alice', SosState.raisedAt(t1));
      await SosStore.save('alice', const SosState.lowered());

      expect((await SosStore.load('alice')).raised, isFalse);
    });

    test('讀不懂的值當作沒有舉著', () async {
      SharedPreferences.setMockInitialValues({'sos_raised:alice': 'garbage'});

      expect((await SosStore.load('alice')).raised, isFalse);
    });
  });

  group('cloudSosWriteFor：health_reports 的任務要不要退回等待中', () {
    CloudSosWrite decide({String? previousStatus, required String status, bool sos = true, String? taskStatus}) =>
        cloudSosWriteFor(previousStatus: previousStatus, status: status, sos: sos, taskStatus: taskStatus);

    test('文件還不存在（沒有已知的 Status）→ 整份寫入', () {
      expect(decide(status: '未宣告'), CloudSosWrite.replace);
    });

    test('Status 改變 → 整份寫入，任務回到等待中', () {
      expect(decide(previousStatus: '安全', status: '未宣告'), CloudSosWrite.replace);
      expect(decide(previousStatus: '未宣告', status: '重傷', sos: false), CloudSosWrite.replace);
    });

    test('只改 SOS 或位置 → 只改那幾個欄位，協助者的認領不受影響', () {
      expect(decide(previousStatus: '重傷', status: '重傷', taskStatus: 'accepted'), CloudSosWrite.patch);
      expect(decide(previousStatus: '未宣告', status: '未宣告'), CloudSosWrite.patch);
      expect(decide(previousStatus: '重傷', status: '重傷', sos: false, taskStatus: 'accepted'), CloudSosWrite.patch);
    });

    test('已完成的任務又舉起 SOS → 重新開一筆，不然沒有人看得到', () {
      expect(decide(previousStatus: '重傷', status: '重傷', taskStatus: 'done'), CloudSosWrite.replace);
      // 撤回 SOS 不必把已完成的任務翻回來
      expect(decide(previousStatus: '重傷', status: '重傷', sos: false, taskStatus: 'done'), CloudSosWrite.patch);
    });
  });

  group('cloudSosFields：寫進 health_reports 的欄位', () {
    final user = (id: 'alice', name: 'Alice', area: '台北市中正區');
    final now = DateTime.utc(2026, 10, 22, 10);

    test('一律寫入 Status 與 SOS：快取的 Status 過期時也不會留下「安全＋SOS」', () {
      final fields = cloudSosFields(CloudSosWrite.patch,
          reporter: user, report: (status: '重傷', sos: true), lat: null, lng: null, now: now);

      expect(fields['status'], '重傷');
      expect(fields['sos'], isTrue);
      expect(fields['reporterId'], 'alice');
      expect(fields['reportTime'], '2026-10-22T10:00:00.000Z');
    });

    test('這次沒有位置時不動既有的座標，不把真的位置抹成 null', () {
      final fields = cloudSosFields(CloudSosWrite.replace,
          reporter: user, report: (status: '未宣告', sos: true), lat: null, lng: null, now: now);

      expect(fields.containsKey('lat'), isFalse);
      expect(fields.containsKey('lng'), isFalse);
    });

    test('有位置就寫入', () {
      final fields = cloudSosFields(CloudSosWrite.patch,
          reporter: user, report: (status: '重傷', sos: true), lat: 25.03, lng: 121.56, now: now);

      expect((fields['lat'], fields['lng']), (25.03, 121.56));
    });

    test('整份寫入時任務回到等待中、舊的傷勢細項清掉', () {
      final fields = cloudSosFields(CloudSosWrite.replace,
          reporter: user, report: (status: '未宣告', sos: true), lat: null, lng: null, now: now);

      expect(fields['taskStatus'], 'waiting');
      expect(fields.containsKey('helperId'), isTrue);
      expect(fields['helperId'], isNull);
      expect(fields.containsKey('description'), isTrue);
      expect(fields['description'], isNull);
      expect(fields['name'], 'Alice');
      expect(fields['area'], '台北市中正區');
    });

    test('只改欄位時不碰任務狀態與傷勢細項', () {
      final fields = cloudSosFields(CloudSosWrite.patch,
          reporter: user, report: (status: '重傷', sos: true), lat: null, lng: null, now: now);

      expect(fields.keys, isNot(contains('taskStatus')));
      expect(fields.keys, isNot(contains('helperId')));
      expect(fields.keys, isNot(contains('description')));
    });

    test('欄位都在 firestore.rules 的 detailTierKeys() 之內', () {
      final fields = cloudSosFields(CloudSosWrite.replace,
          reporter: user, report: (status: '重傷', sos: true), lat: 25.0, lng: 121.5, now: now);

      expect(
        fields.keys.toSet().difference({
          'id', 'reporterId', 'name', 'area', 'status', 'description',
          'lat', 'lng', 'reportTime', 'sos', 'taskStatus', 'helperId',
        }),
        isEmpty,
      );
    });
  });

  group('cloudSosSensitiveFields：寫進 health_report_sensitive 的欄位', () {
    final user = AppUser(
      id: 'alice',
      name: 'Alice',
      phone: '0912345678',
      area: '台北市中正區',
      emergencyContactName: '王大明',
      emergencyContactPhone: '0987654321',
      emergencyContactRelation: '父親',
      bloodType: 'O',
      medicalInfo: '盤尼西林過敏',
      registeredAt: DateTime(2024),
    );

    test('只帶個人檔案的聯絡與醫療資訊', () {
      expect(cloudSosSensitiveFields(user), {
        'reporterId': 'alice',
        'phone': '0912345678',
        'bloodType': 'O',
        'medicalInfo': '盤尼西林過敏',
        'emergencyContactName': '王大明',
        'emergencyContactPhone': '0987654321',
        'emergencyContactRelation': '父親',
      });
    });

    test('不帶 surveySensitive：merge 寫入時才不會清掉健康回報填過的調查（ADR-0007）', () {
      expect(cloudSosSensitiveFields(user).keys, isNot(contains('surveySensitive')));
    });
  });

  group('SosDelivery：mesh 與雲端兩條路的結果', () {
    test('都送出、有位置', () {
      const d = SosDelivery(withLocation: true);

      expect(d.message, 'SOS 已發送，請保持冷靜等待救援。');
      expect(d.complete, isTrue);
      expect(d.failed, isFalse);
    });

    test('都送出、沒有位置', () {
      const d = SosDelivery(withLocation: false);

      expect(d.message, 'SOS 已發送，但沒有附上位置，請設法告知所在地。');
      expect(d.complete, isFalse);
    });

    test('mesh 已送出、雲端逾時：說附近裝置已收到，不是失敗', () {
      const d = SosDelivery(withLocation: true, uploadQueued: true);

      expect(d.message, '附近裝置已收到求救，雲端尚未上傳，恢復連線後會自動送出。');
      expect(d.failed, isFalse);
      expect(d.complete, isFalse);
    });

    test('mesh 已送出、雲端失敗', () {
      const d = SosDelivery(withLocation: true, uploadFailure: 'permission-denied');

      expect(d.message, '附近裝置已收到求救，但雲端上傳失敗（permission-denied）。');
      expect(d.failed, isFalse);
    });

    test('mesh 失敗、雲端送到', () {
      const d = SosDelivery(withLocation: true, broadcastFailure: 'mesh 尚未啟動');

      expect(d.message, '求救已上傳雲端，但附近廣播失敗（mesh 尚未啟動）。');
      expect(d.failed, isFalse);
    });

    test('mesh 失敗、雲端暫存', () {
      const d = SosDelivery(withLocation: true, broadcastFailure: 'mesh 尚未啟動', uploadQueued: true);

      expect(d.message, '目前離線，附近廣播也失敗（mesh 尚未啟動）。求救已暫存，恢復連線後會自動送出。');
      expect(d.failed, isFalse);
    });

    test('兩條路都失敗', () {
      const d = SosDelivery(withLocation: true, broadcastFailure: 'mesh 尚未啟動', uploadFailure: 'unavailable');

      expect(d.message, '發送失敗：附近廣播失敗（mesh 尚未啟動），雲端上傳也失敗（unavailable）。請再試一次。');
      expect(d.failed, isTrue);
    });

    test('reachedSomeone：mesh 送出、或雲端確認收到，才算有人收到', () {
      expect(const SosDelivery(withLocation: true).reachedSomeone, isTrue);
      expect(const SosDelivery(withLocation: true, uploadQueued: true).reachedSomeone, isTrue);
      expect(const SosDelivery(withLocation: true, broadcastFailure: 'x').reachedSomeone, isTrue);
      expect(const SosDelivery(withLocation: true, broadcastFailure: 'x', uploadQueued: true).reachedSomeone, isFalse);
      expect(const SosDelivery(withLocation: true, broadcastFailure: 'x', uploadFailure: 'y').reachedSomeone, isFalse);
    });

    test('withUpload：暫存的上傳之後送到或失敗，其餘結果不變', () {
      const queued = SosDelivery(withLocation: false, broadcastFailure: 'x', uploadQueued: true);

      final arrived = queued.withUpload();
      expect((arrived.withLocation, arrived.broadcastFailure, arrived.uploadQueued, arrived.uploadFailure),
          (false, 'x', false, null));

      final lost = queued.withUpload(failure: 'permission-denied');
      expect((lost.uploadQueued, lost.uploadFailure, lost.failed), (false, 'permission-denied', true));
    });

    test('有但書又沒有位置時，兩件事都要說', () {
      const d = SosDelivery(withLocation: false, uploadQueued: true);

      expect(d.message, '附近裝置已收到求救，雲端尚未上傳，恢復連線後會自動送出。沒有附上位置，請設法告知所在地。');
    });
  });
}
