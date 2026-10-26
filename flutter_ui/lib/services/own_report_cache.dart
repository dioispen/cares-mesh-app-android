import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 本機的 Reporter Handle 存在這個鍵。名稱沿用舊版，已產生的 handle 不會換掉。
const _reporterHandleKey = 'broadcast_handle';

/// 取得（或首次產生）本機的 Reporter Handle。Health 畫面與 SOS 畫面都用它，救援端才能把
/// 同一位 Reporter 的 SOS 與後續 Health Report 串在一起。
///
/// 這是刻意**不從帳號衍生**的隨機值：不用 Firebase UID、電話或姓名雜湊，讓長期側錄者無法
/// 把 handle 反推回本人或 Firestore 文件（ADR-0003）。一經產生即固定，綁裝置而非帳號。
Future<String> loadOrCreateReporterHandle(SharedPreferences prefs) async {
  var handle = prefs.getString(_reporterHandleKey);
  if (handle == null || !RegExp(r'^[0-9a-f]{12}$').hasMatch(handle)) {
    final rng = Random.secure();
    handle = List<String>.generate(
      6,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await prefs.setString(_reporterHandleKey, handle);
  }
  return handle;
}

/// 最近一次回報的 Status 與傷勢細項，本機快取。
///
/// 「我的狀態」是每個帳號各自的資料，所以鍵值綁 uid：同一台裝置換帳號登入不會讀到前一個人的
/// 狀態。登出時刻意保留（`AccountService.signOut`）。Health 畫面以後端文件為準，這份快取是
/// 監聽還沒回來前的離線初值；SOS 畫面據此決定送出的 Status（`sosStatusFor`）。
abstract final class OwnStatusCache {
  static String _statusKey(String uid) => 'health_status:$uid';
  static String _subInjuryKey(String uid) => 'health_sub_injury:$uid';

  static Future<({String? status, String? subInjury})> load(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return (status: prefs.getString(_statusKey(uid)), subInjury: prefs.getString(_subInjuryKey(uid)));
  }

  static Future<void> save(String uid, String status, String? subInjury) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_statusKey(uid), status);
    if (subInjury != null) {
      await prefs.setString(_subInjuryKey(uid), subInjury);
    } else {
      await prefs.remove(_subInjuryKey(uid));
    }
  }
}
