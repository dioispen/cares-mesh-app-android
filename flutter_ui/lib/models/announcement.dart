/// 管理端廣播的一則訊息（Firestore `announcements` 集合）。
///
/// 文件只能由管理者在 Firebase 主控台新增，App 只讀；欄位說明見 docs/announcements.md。
class Announcement {
  final String id;
  final String body;
  final String? title;

  /// 'all'：發給所有使用者；'user'：只發給 [targetUid]。
  final String audience;
  final String? targetUid;

  /// 重要程度，影響畫面上的標示：'info'（一般）、'important'（重要）、'urgent'（緊急）。
  final String level;
  final DateTime createdAt;

  const Announcement({
    required this.id,
    required this.body,
    this.title,
    required this.audience,
    this.targetUid,
    this.level = 'info',
    required this.createdAt,
  });

  bool get isForEveryone => audience == 'all';

  /// 從 Firestore 文件建立。[createdAt] 在主控台可能被填成 timestamp 或字串，兩種都接受；
  /// 缺少內文或時間的文件（填到一半的草稿）回傳 null，不顯示。
  static Announcement? fromMap(String id, Map<String, dynamic> data) {
    final body = data['body'];
    final createdAt = _parseTime(data['createdAt']);
    if (body is! String || body.trim().isEmpty || createdAt == null) return null;
    final title = data['title'];
    final level = data['level'];
    return Announcement(
      id: id,
      body: body.trim(),
      title: title is String && title.trim().isNotEmpty ? title.trim() : null,
      audience: data['audience'] == 'user' ? 'user' : 'all',
      targetUid: data['targetUid'] as String?,
      level: const {'info', 'important', 'urgent'}.contains(level) ? level as String : 'info',
      createdAt: createdAt,
    );
  }

  static DateTime? _parseTime(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    // cloud_firestore 的 Timestamp：不直接依賴套件型別，方便在純 Dart 測試裡使用。
    try {
      return (value as dynamic)?.toDate() as DateTime?;
    } catch (_) {
      return null;
    }
  }
}

/// 把「發給全體」與「發給自己」兩個查詢的結果合成一份由舊到新的清單（同一則只出現一次）。
List<Announcement> mergeAnnouncements(
  Iterable<Announcement> forEveryone,
  Iterable<Announcement> forMe,
) {
  final byId = <String, Announcement>{
    for (final a in forEveryone) a.id: a,
    for (final a in forMe) a.id: a,
  };
  return byId.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
}

/// 比 [lastRead] 新的廣播數量；從沒讀過（null）時全部算未讀。
int unreadAnnouncementCount(List<Announcement> all, DateTime? lastRead) =>
    lastRead == null ? all.length : all.where((a) => a.createdAt.isAfter(lastRead)).length;
