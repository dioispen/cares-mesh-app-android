import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/screens/supply_screen.dart';

/// 物資頁「我的申請／我的捐贈」的排序。
void main() {
  test('newest first, and records not yet synced to the cloud (no time) come before all of them', () {
    final older = DateTime(2026, 11, 20, 9);
    final newer = DateTime(2026, 11, 20, 10);
    final times = <DateTime?>[older, null, newer]..sort(compareNewestFirst);

    expect(times, [null, newer, older]);
  });
}
