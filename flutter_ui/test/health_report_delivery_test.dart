import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart';
import 'package:flutter_ui/models/health_report_delivery.dart';

/// What the Health Report screen tells the user about the two deliveries of one report: the BLE
/// broadcast of its Broadcast Tier to people nearby, and the upload to the cloud.
void main() {
  group('the message reflects both deliveries', () {
    test('both delivered', () {
      const delivery = HealthReportDelivery();

      expect(delivery.message('重傷'), '已回報：重傷');
      expect(delivery.complete, isTrue);
      expect(delivery.failed, isFalse);
    });

    test('only the cloud got it: nearby rescuers did not', () {
      const delivery = HealthReportDelivery(broadcastFailure: 'mesh 尚未啟動');

      expect(delivery.message('重傷'), '已上傳雲端，但附近廣播失敗：mesh 尚未啟動');
      expect(delivery.complete, isFalse);
      expect(delivery.failed, isFalse);
    });

    test('only the broadcast went out', () {
      const delivery = HealthReportDelivery(uploadFailure: 'unavailable');

      expect(delivery.message('輕傷'), '已向附近廣播：輕傷，但雲端上傳失敗：unavailable');
      expect(delivery.complete, isFalse);
      expect(delivery.failed, isFalse);
    });

    test('neither got it', () {
      const delivery = HealthReportDelivery(broadcastFailure: 'mesh 尚未啟動', uploadFailure: 'unavailable');

      expect(delivery.message('重傷'), '回報失敗：附近廣播失敗（mesh 尚未啟動），雲端上傳也失敗（unavailable）');
      expect(delivery.failed, isTrue);
    });
  });

  group('a broadcast failure is explained', () {
    test('by the reason the native side gave', () {
      expect(
        HealthReportDelivery.broadcastFailureReason(PlatformException(code: HealthReportErrors.serviceNotReady)),
        'mesh 尚未啟動',
      );
      expect(
        HealthReportDelivery.broadcastFailureReason(PlatformException(code: HealthReportErrors.invalidFormat)),
        '回報內容格式不符',
      );
      expect(
        HealthReportDelivery.broadcastFailureReason(PlatformException(code: HealthReportErrors.sendFailed)),
        '交給 mesh 時發生錯誤',
      );
      expect(HealthReportDelivery.broadcastFailureReason(PlatformException(code: 'NEW_CODE')), '原生錯誤（NEW_CODE）');
    });

    test('without a native mesh (iOS, tests) it says the device cannot broadcast', () {
      expect(
        HealthReportDelivery.broadcastFailureReason(MissingPluginException('no implementation')),
        '此裝置不支援附近廣播',
      );
    });
  });
}
