import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/announcement.dart';

Announcement _a(String id, DateTime t, {String audience = 'all'}) =>
    Announcement(id: id, body: '內容 $id', audience: audience, createdAt: t);

void main() {
  group('Announcement.fromMap', () {
    test('解析主控台填的欄位，createdAt 可以是字串', () {
      final a = Announcement.fromMap('a1', {
        'title': ' 停水通知 ',
        'body': '今晚 8 點起停水，請預先儲水',
        'audience': 'all',
        'level': 'important',
        'createdAt': '2026-10-20T08:00:00',
      })!;
      expect(a.title, '停水通知');
      expect(a.isForEveryone, isTrue);
      expect(a.level, 'important');
      expect(a.createdAt, DateTime(2026, 10, 20, 8));
    });

    test('指定對象的廣播保留 targetUid', () {
      final a = Announcement.fromMap('a2', {
        'body': '您申請的輪椅已送達',
        'audience': 'user',
        'targetUid': 'uid-alice',
        'createdAt': DateTime(2026, 10, 20),
      })!;
      expect(a.isForEveryone, isFalse);
      expect(a.targetUid, 'uid-alice');
    });

    test('未知的 level 退回 info，空白 title 視為沒有', () {
      final a = Announcement.fromMap('a3', {
        'body': '內容',
        'title': '  ',
        'level': '超級緊急',
        'createdAt': DateTime(2026),
      })!;
      expect(a.level, 'info');
      expect(a.title, isNull);
    });

    test('缺內文或時間的草稿不顯示', () {
      expect(Announcement.fromMap('x', {'createdAt': DateTime(2026)}), isNull);
      expect(Announcement.fromMap('x', {'body': '  ', 'createdAt': DateTime(2026)}), isNull);
      expect(Announcement.fromMap('x', {'body': '內容'}), isNull);
      expect(Announcement.fromMap('x', {'body': '內容', 'createdAt': '不是日期'}), isNull);
    });
  });

  test('mergeAnnouncements：兩個查詢合併後由舊到新，同一則不重複', () {
    final t = DateTime(2026, 10, 20);
    final merged = mergeAnnouncements(
      [_a('all-2', t.add(const Duration(hours: 2))), _a('all-1', t)],
      [_a('me-1', t.add(const Duration(hours: 1)), audience: 'user'), _a('all-1', t)],
    );
    expect(merged.map((a) => a.id), ['all-1', 'me-1', 'all-2']);
  });

  test('unreadAnnouncementCount：只算比已讀時間新的；從沒讀過全部算未讀', () {
    final t = DateTime(2026, 10, 20);
    final items = [_a('1', t), _a('2', t.add(const Duration(hours: 1)))];
    expect(unreadAnnouncementCount(items, null), 2);
    expect(unreadAnnouncementCount(items, t), 1);
    expect(unreadAnnouncementCount(items, t.add(const Duration(hours: 1))), 0);
    expect(unreadAnnouncementCount(const [], null), 0);
  });
}
