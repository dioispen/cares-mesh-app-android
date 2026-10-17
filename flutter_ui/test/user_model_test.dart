import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/widgets/user_avatar.dart';

void main() {
  final legacyJson = {
    'id': 'uid-1',
    'email': 'a@example.com',
    'name': '王小明',
    'phone': '0912345678',
    'area': '南投縣埔里鎮',
    'emergencyContactName': '王媽媽',
    'emergencyContactPhone': '0987654321',
    'emergencyContactRelation': '母親',
    'bloodType': null,
    'medicalInfo': null,
    'registeredAt': '2026-09-01T10:00:00.000',
  };

  test('沒有 avatar 欄位的舊帳號資料仍可解析，avatar 為 null', () {
    final user = AppUser.fromJson(legacyJson);
    expect(user.avatar, isNull);
  });

  test('avatar 經過 toJson / fromJson 後保留', () {
    final user = AppUser.fromJson(legacyJson).withAvatar('rabbit');
    final restored = AppUser.fromJson(user.toJson());
    expect(restored.avatar, 'rabbit');
    expect(restored.avatarPhoto, isNull);
    expect(restored.name, '王小明');
  });

  test('自選照片會保存；換回預設頭像時照片被清掉', () {
    final withPhoto = AppUser.fromJson(legacyJson).withAvatar(photoAvatarId, avatarPhoto: 'AAAA');
    final restored = AppUser.fromJson(withPhoto.toJson());
    expect(restored.avatar, photoAvatarId);
    expect(restored.avatarPhoto, 'AAAA');

    final backToPreset = restored.withAvatar('cat');
    expect(backToPreset.avatar, 'cat');
    expect(backToPreset.avatarPhoto, isNull);
  });

  test('預設大頭貼 id 不重複，且都查得到', () {
    final ids = avatarPresets.map((p) => p.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids, isNot(contains(photoAvatarId)));
    for (final id in ids) {
      expect(avatarPresetById(id), isNotNull);
    }
    expect(avatarPresetById('unknown'), isNull);
    expect(avatarPresetById(null), isNull);
  });
}
