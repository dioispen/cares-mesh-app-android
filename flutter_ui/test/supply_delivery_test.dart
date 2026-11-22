import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/supply_delivery.dart';

/// 物資頁送出後給使用者看的說法：mesh 廣播與雲端寫入各自成功與否。
void main() {
  test('both delivered', () {
    const d = SupplyDelivery();
    expect(d.complete, isTrue);
    expect(d.failed, isFalse);
    expect(d.message('已送出申請'), '已送出申請：已透過 Mesh 廣播給附近裝置，並記錄到雲端。');
  });

  test('offline: the broadcast went out and the upload is queued', () {
    const d = SupplyDelivery(uploadQueued: true);
    expect(d.complete, isFalse);
    expect(d.failed, isFalse);
    expect(d.recorded, isTrue, reason: '進了離線佇列就算記下，重送會重複計算');
    expect(d.message('已送出申請'), '已送出申請：附近裝置已收到，雲端尚未上傳，恢復連線後會自動送出。');
  });

  test('offline and no mesh: queued only', () {
    const d = SupplyDelivery(broadcastFailure: '藍牙 Mesh 尚未啟動', uploadQueued: true);
    expect(d.failed, isFalse);
    expect(d.message('已送出申請'), '目前離線，附近廣播也失敗（藍牙 Mesh 尚未啟動）。已送出申請已暫存，恢復連線後會自動送出。');
  });

  test('only the cloud got it', () {
    const d = SupplyDelivery(broadcastFailure: '此裝置沒有藍牙 Mesh');
    expect(d.recorded, isTrue);
    expect(d.message('感謝您的捐贈承諾'), '感謝您的捐贈承諾：已記錄到雲端，但附近廣播失敗（此裝置沒有藍牙 Mesh）。');
  });

  test('only the broadcast went out', () {
    const d = SupplyDelivery(uploadFailure: 'permission-denied');
    expect(d.recorded, isFalse);
    expect(d.message('已送出申請'), '已送出申請：附近裝置已收到，但雲端上傳失敗（permission-denied），請再送一次。');
  });

  test('both failed', () {
    const d = SupplyDelivery(broadcastFailure: 'a', uploadFailure: 'b');
    expect(d.failed, isTrue);
    expect(d.recorded, isFalse);
    expect(d.message('已送出申請'), '送出失敗：附近廣播失敗（a），雲端上傳也失敗（b）。請再試一次。');
  });

  group('PendingSubmissionIds', () {
    late int minted;
    late PendingSubmissionIds ids;
    setUp(() {
      minted = 0;
      ids = PendingSubmissionIds(newId: () => 'id-${++minted}');
    });

    test('a retry after the cloud refused reuses the id, so mesh and cloud share one exchangeId', () {
      final first = ids.idFor('water');
      ids.settle('water', const SupplyDelivery(uploadFailure: 'permission-denied'));

      expect(ids.idFor('water'), first);
    });

    test('once recorded (written or queued offline), the next submission gets a new id', () {
      final first = ids.idFor('water');
      ids.settle('water', const SupplyDelivery(uploadQueued: true));

      expect(ids.idFor('water'), isNot(first));
    });

    test('items keep separate ids', () {
      expect(ids.idFor('water'), isNot(ids.idFor('rice')));
    });
  });
}
