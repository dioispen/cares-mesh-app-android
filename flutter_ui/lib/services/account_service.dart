import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bitchat_bridge.dart';
import 'mutual_aid_task_board.dart';
import 'profile_store.dart';

/// 設定頁「帳號與資料」的兩個動作（#80）。建構子的參數只給測試注入替身。
class AccountService {
  AccountService({
    Future<void> Function()? signOutFirebase,
    Future<void> Function()? nativePanicClear,
    void Function()? clearMutualAidTasks,
  })  : _signOutFirebase = signOutFirebase ?? (() => FirebaseAuth.instance.signOut()),
        _nativePanicClear = nativePanicClear ?? BitchatBridge.panicClear,
        _clearMutualAidTasks = clearMutualAidTasks ?? MutualAidTaskBoard.instance.clear;

  final Future<void> Function() _signOutFirebase;
  final Future<void> Function() _nativePanicClear;

  /// 忘掉記憶體裡收到的互救任務與本機進度（[MutualAidTaskBoard.clear]）。
  final void Function() _clearMutualAidTasks;

  /// 登出 Firebase、忘掉本機的個人資料。
  ///
  /// 健康狀態的快取刻意保留：鍵值綁 uid，不可能被別的帳號讀到，留著才能在重新登入、而且當下
  /// 連不上 Firestore 時，立刻看到自己回報過的狀態。登出就清掉的話，離線重新登入會變成一片空白。
  /// broadcast_handle 同樣保留：它綁裝置而非帳號（ADR-0003）。互救任務的本機進度不保留：
  /// 下一個登入的人不該看到前一個人接了哪些任務。
  Future<void> signOut() async {
    await _signOutFirebase();
    _clearMutualAidTasks();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(appUserPrefsKey);
  }

  /// 緊急清除：先由原生清除聊天紀錄、身分金鑰、媒體檔與通知；原生沒有清乾淨就往上拋，
  /// 其他東西都不動，讓使用者可以再試一次。原生成功後才清掉本機的個人資料（含註冊到一半的
  /// `pending_app_user`）與記憶體裡的互救任務，再登出 Firebase；登出失敗時這些也已經清了。
  /// Firestore 上的雲端資料不刪除。
  Future<void> panicClear() async {
    await _nativePanicClear();
    _clearMutualAidTasks();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(appUserPrefsKey);
    await prefs.remove(pendingAppUserPrefsKey);
    try {
      await _signOutFirebase();
    } catch (e) {
      throw PanicSignOutFailed(e);
    }
  }
}

/// 緊急清除時原生與本機資料都已清除，只有登出 Firebase 失敗：不必、也不該再清一次。
class PanicSignOutFailed implements Exception {
  PanicSignOutFailed(this.cause);

  final Object cause;

  @override
  String toString() => 'PanicSignOutFailed($cause)';
}
