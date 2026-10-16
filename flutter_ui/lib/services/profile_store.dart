import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';

/// 本機存的登入帳號個人資料（SharedPreferences）的鍵。
const appUserPrefsKey = 'app_user';

/// 註冊後、Email 驗證前暫存的個人資料（`register_screen.dart`）的鍵。
const pendingAppUserPrefsKey = 'pending_app_user';

/// 一次存檔的雲端那一半：本機已寫入，[synced] 在 Firestore 確認寫入時完成，失敗時帶錯誤。
///
/// 離線時 Firestore 先把寫入留在本機佇列，連上網才送出，[synced] 會一直等到那時。
class ProfileSync {
  const ProfileSync(this.synced);

  final Future<void> synced;
}

/// 帳號個人資料的兩份副本（#80）：本機的 `app_user` 與 Firestore 的 `users/{uid}`。
///
/// 一律先寫本機，畫面立刻反映，再寫雲端。`firestore.rules` 只允許本人讀寫自己的文件。
class ProfileStore {
  /// [writeRemote] 以 merge 寫入 `users/{uid}` 的這些欄位，值為 null 的欄位刪除；只給測試注入。
  ProfileStore({Future<void> Function(String uid, Map<String, Object?> fields)? writeRemote})
      : _writeRemote = writeRemote ?? _writeFirestore;

  final Future<void> Function(String uid, Map<String, Object?> fields) _writeRemote;

  static Future<void> _writeFirestore(String uid, Map<String, Object?> fields) =>
      FirebaseFirestore.instance.collection('users').doc(uid).set(
        {for (final MapEntry(:key, :value) in fields.entries) key: value ?? FieldValue.delete()},
        SetOptions(merge: true),
      );

  Future<AppUser?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(appUserPrefsKey);
    return raw == null ? null : AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// 設定頁編輯的欄位；Email、User ID、註冊時間與大頭貼不在其中。
  Future<ProfileSync> saveProfile(AppUser user) => _save(user, {
        'name': user.name,
        'phone': user.phone,
        'area': user.area,
        'emergencyContactName': user.emergencyContactName,
        'emergencyContactPhone': user.emergencyContactPhone,
        'emergencyContactRelation': user.emergencyContactRelation,
        'bloodType': user.bloodType,
        'medicalInfo': user.medicalInfo,
      });

  /// 換大頭貼。選回預設頭像時 `avatarPhoto` 為 null，雲端的舊照片一併刪除。
  Future<ProfileSync> saveAvatar(AppUser user) =>
      _save(user, {'avatar': user.avatar, 'avatarPhoto': user.avatarPhoto});

  Future<ProfileSync> _save(AppUser user, Map<String, Object?> remoteFields) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(appUserPrefsKey, jsonEncode(user.toJson()));
    return ProfileSync(_writeRemote(user.id, remoteFields));
  }
}
