import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/own_report_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('loadOrCreateReporterHandle：Health 與 SOS 畫面用同一個 Reporter Handle', () {
    test('第一次產生 12 個十六進位字元，之後讀回同一個', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final first = await loadOrCreateReporterHandle(prefs);
      final second = await loadOrCreateReporterHandle(prefs);

      expect(first, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(second, first);
    });

    test('沿用舊版已存的 broadcast_handle', () async {
      SharedPreferences.setMockInitialValues({'broadcast_handle': 'abcdef012345'});

      expect(await loadOrCreateReporterHandle(await SharedPreferences.getInstance()), 'abcdef012345');
    });

    test('存的值格式不對就換一個新的', () async {
      SharedPreferences.setMockInitialValues({'broadcast_handle': 'not-a-handle'});

      expect(
        await loadOrCreateReporterHandle(await SharedPreferences.getInstance()),
        matches(RegExp(r'^[0-9a-f]{12}$')),
      );
    });
  });

  group('OwnStatusCache：最近一次的 Status 綁帳號', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('存了再讀回來', () async {
      await OwnStatusCache.save('alice', '輕傷', '割傷');

      expect(await OwnStatusCache.load('alice'), (status: '輕傷', subInjury: '割傷'));
    });

    test('沒有傷勢細項時清掉舊的細項', () async {
      await OwnStatusCache.save('alice', '輕傷', '割傷');
      await OwnStatusCache.save('alice', '未宣告', null);

      expect(await OwnStatusCache.load('alice'), (status: '未宣告', subInjury: null));
    });

    test('換帳號讀不到前一個人的 Status', () async {
      await OwnStatusCache.save('alice', '重傷', null);

      expect(await OwnStatusCache.load('bob'), (status: null, subInjury: null));
    });

    test('沿用 #60 的鍵值，既有的快取不會不見', () async {
      SharedPreferences.setMockInitialValues({
        'health_status:alice': '重傷',
        'health_sub_injury:alice': '四肢骨折',
      });

      expect(await OwnStatusCache.load('alice'), (status: '重傷', subInjury: '四肢骨折'));
    });
  });
}
