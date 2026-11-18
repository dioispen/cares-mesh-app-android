import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/announcement.dart';

/// 讀取管理端廣播，並記錄「讀到哪裡」以計算未讀數。
class AnnouncementService {
  AnnouncementService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// 自己看得到的所有廣播，由舊到新，資料有變動就重新送出。
  ///
  /// 分成兩個查詢，因為 firestore.rules 只允許讀「發給全體」或「發給自己」的文件：
  /// 不帶條件列出整個集合會被整批拒絕。「發給自己」必須同時篩 audience 與 targetUid，
  /// 規則才能從查詢條件證明結果都可讀。不在查詢上排序，免得需要建立複合索引。
  Stream<List<Announcement>> watch(String uid) {
    final col = _db.collection('announcements');
    final everyoneQuery = col.where('audience', isEqualTo: 'all');
    final mineQuery =
        col.where('audience', isEqualTo: 'user').where('targetUid', isEqualTo: uid);

    late final StreamController<List<Announcement>> controller;
    List<Announcement>? everyone;
    List<Announcement>? mine;
    final subs = <StreamSubscription>[];

    List<Announcement> parse(QuerySnapshot<Map<String, dynamic>> snap) => [
          for (final d in snap.docs) ?Announcement.fromMap(d.id, d.data()),
        ];

    void emit() {
      // 兩個查詢都回來之後才送出，避免先閃出半份清單、未讀數跳動。
      if (everyone != null && mine != null) {
        controller.add(mergeAnnouncements(everyone!, mine!));
      }
    }

    controller = StreamController<List<Announcement>>(
      onListen: () {
        subs.add(everyoneQuery.snapshots().listen((s) {
          everyone = parse(s);
          emit();
        }, onError: controller.addError));
        subs.add(mineQuery.snapshots().listen((s) {
          mine = parse(s);
          emit();
        }, onError: controller.addError));
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return controller.stream;
  }

  static String _lastReadKey(String uid) => 'announcements_last_read_$uid';

  Future<DateTime?> lastRead(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_lastReadKey(uid));
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// 標記為已讀到 [upTo]（通常是畫面上最新一則的時間）。只會往後推，不會倒退。
  Future<void> markRead(String uid, DateTime upTo) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(_lastReadKey(uid)) ?? 0;
    if (upTo.millisecondsSinceEpoch > current) {
      await prefs.setInt(_lastReadKey(uid), upTo.millisecondsSinceEpoch);
    }
  }
}
