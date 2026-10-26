import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bitchat_bridge.dart';
import 'own_report_cache.dart';

/// Ed25519 公鑰的長度；`firestore.rules` 只收這個長度的 `signingPublicKey`。
const _signingPublicKeyLength = 32;

/// Reporter 本人登記「這次安裝的 Reporter Handle 屬於我」（#110，docs/MESH_GATEWAY.md 7.7）：
/// 寫進 `reporter_handles/{uid}/installations/{reporterHandle}`，讓管理後台能把 Gateway 代傳的
/// `mesh_reports` 對回已註冊的帳號，並與 `health_reports` 去重。
///
/// 每次都整份覆寫（idempotent），不等到送出回報才登記：最需要這份對應的，是登記之後就再也
/// 沒有網路的人。離線時交給 Firestore 的離線佇列。只有 Administrator 與本人讀得到（ADR-0009）。
///
/// 建構子的參數只給測試注入替身，比照 `ProfileStore`。
class ReporterHandleRegistration {
  ReporterHandleRegistration({
    Future<void> Function(String uid, String reporterHandle, Map<String, Object> fields)? writeRemote,
    Future<String> Function()? loadReporterHandle,
    Future<Uint8List?> Function()? loadSigningPublicKey,
  })  : _writeRemote = writeRemote ?? _writeFirestore,
        _loadReporterHandle = loadReporterHandle ?? _loadStoredReporterHandle,
        _loadSigningPublicKey = loadSigningPublicKey ?? BitchatBridge.getSigningPublicKey;

  /// 以 `set`（整份覆寫、不 merge）寫入那份文件；文件 ID 就是 [reporterHandle]。
  final Future<void> Function(String uid, String reporterHandle, Map<String, Object> fields) _writeRemote;
  final Future<String> Function() _loadReporterHandle;
  final Future<Uint8List?> Function() _loadSigningPublicKey;

  static Future<void> _writeFirestore(String uid, String reporterHandle, Map<String, Object> fields) =>
      FirebaseFirestore.instance
          .collection('reporter_handles')
          .doc(uid)
          .collection('installations')
          .doc(reporterHandle)
          .set(fields);

  static Future<String> _loadStoredReporterHandle() async =>
      loadOrCreateReporterHandle(await SharedPreferences.getInstance());

  /// 已登入（[uid] 不為 null）時登記一次；未登入時什麼都不做。
  ///
  /// 永遠不拋錯，也不提示使用者：拿不到簽章公鑰（mesh 服務還不存在、沒有原生 mesh）時這次
  /// 略過，雲端寫入失敗時只留 log，下次啟動或登入再試。完成於 Firestore 確認寫入、或確定
  /// 略過或失敗時；離線時會一直等到連上網路。
  Future<void> register(String? uid) async {
    if (uid == null) return;

    final Uint8List? key;
    try {
      key = await _loadSigningPublicKey();
    } on PlatformException catch (e) {
      debugPrint('Reporter Handle registration skipped: no signing key (${e.code})');
      return;
    } on MissingPluginException {
      debugPrint('Reporter Handle registration skipped: no native mesh on this platform');
      return;
    } catch (e) {
      debugPrint('Reporter Handle registration skipped: signing key unavailable: $e');
      return;
    }
    if (key == null || key.length != _signingPublicKeyLength) {
      debugPrint('Reporter Handle registration skipped: signing key has ${key?.length} bytes');
      return;
    }

    try {
      final handle = await _loadReporterHandle();
      await _writeRemote(uid, handle, {
        'reporterHandle': handle,
        'signingPublicKey': Blob(key),
        'registeredAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Reporter Handle registration failed: $e');
    }
  }
}

/// App 啟動與每次登入成功後各登記一次（#110）。
///
/// [uids] 是登入狀態：目前的 uid，未登入時為 null。`FirebaseAuth.authStateChanges` 正是這樣：
/// 訂閱時先給目前的使用者，之後每次登入、登出各給一次；所以登入畫面不必另外觸發。
/// 串流或 [register] 出錯都只留 log，不會往外拋，之後的登入照樣登記。
StreamSubscription<String?> registerReporterHandleOnSignIn(
  Stream<String?> uids,
  Future<void> Function(String uid) register,
) =>
    uids.listen(
      (uid) {
        if (uid == null) return;
        unawaited(Future.sync(() => register(uid)).catchError((Object e) {
          debugPrint('Reporter Handle registration failed: $e');
        }));
      },
      onError: (Object e) => debugPrint('Sign-in state unavailable for Reporter Handle registration: $e'),
    );
