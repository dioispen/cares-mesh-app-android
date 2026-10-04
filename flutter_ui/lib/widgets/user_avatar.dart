import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bitchat_bridge.dart';

/// 一個預設大頭貼：用 emoji 動物配上柔和底色，不需要額外圖檔。
class AvatarPreset {
  final String id;
  final String emoji;
  final String label;
  final Color background;

  const AvatarPreset(this.id, this.emoji, this.label, this.background);
}

/// 預設大頭貼清單。id 會存進 AppUser.avatar 與 Firestore，
/// 已發出去的 id 不要改名或移除，否則舊帳號會退回顯示姓名首字。
const avatarPresets = <AvatarPreset>[
  AvatarPreset('cat', '🐱', '貓咪', Color(0xFFFBE3D3)),
  AvatarPreset('dog', '🐶', '狗狗', Color(0xFFF3E6C8)),
  AvatarPreset('rabbit', '🐰', '兔兔', Color(0xFFF8DDE6)),
  AvatarPreset('bear', '🐻', '熊熊', Color(0xFFEADBCB)),
  AvatarPreset('panda', '🐼', '熊貓', Color(0xFFE4E8E1)),
  AvatarPreset('fox', '🦊', '狐狸', Color(0xFFFCDCC5)),
  AvatarPreset('koala', '🐨', '無尾熊', Color(0xFFDDE5EE)),
  AvatarPreset('frog', '🐸', '青蛙', Color(0xFFDCEBD3)),
];

/// AppUser.avatar 為此值時，顯示 AppUser.avatarPhoto 這張自選照片。
const photoAvatarId = 'photo';

/// 只快取最近一張：畫面上同時出現的自選照片只會是自己的那一張，
/// 避免每次 rebuild 都重新 base64 解碼、Image.memory 也因此不會閃爍。
String? _cachedPhotoBase64;
Uint8List? _cachedPhotoBytes;

Uint8List? _photoBytes(String? base64) {
  if (base64 == null || base64.isEmpty) return null;
  if (base64 != _cachedPhotoBase64) {
    try {
      _cachedPhotoBytes = base64Decode(base64);
    } on FormatException {
      _cachedPhotoBytes = null;
    }
    _cachedPhotoBase64 = base64;
  }
  return _cachedPhotoBytes;
}

/// 開啟裝置相簿挑一張照片，回傳 base64 的 JPEG 縮圖；取消或失敗時為 null。
/// 失敗原因會用 SnackBar 告訴使用者，呼叫端不必再提示。
Future<String?> pickAvatarPhoto(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  void tell(String msg) => messenger.showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ));
  try {
    final bytes = await BitchatBridge.pickAvatarPhoto();
    if (bytes == null) return null; // 使用者取消
    return base64Encode(bytes);
  } on MissingPluginException {
    tell('這個裝置目前不支援從相簿選照片');
  } on PlatformException catch (e) {
    debugPrint('pickAvatarPhoto failed: ${e.code} ${e.message}');
    tell('讀取照片失敗，請換一張再試');
  }
  return null;
}

AvatarPreset? avatarPresetById(String? id) {
  for (final p in avatarPresets) {
    if (p.id == id) return p;
  }
  return null;
}

/// 圓形大頭貼。選過預設頭像就顯示動物，沒選過（舊帳號）就退回姓名首字。
class UserAvatarCircle extends StatelessWidget {
  final String? avatarId;
  final String? photo;
  final String? name;
  final double size;

  const UserAvatarCircle({
    super.key,
    required this.avatarId,
    this.photo,
    required this.name,
    this.size = 42,
  });

  static const _brown = Color(0xFF5C3D2E);

  @override
  Widget build(BuildContext context) {
    final photoBytes = avatarId == photoAvatarId ? _photoBytes(photo) : null;
    if (photoBytes != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: size * 0.06),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3D2C1E).withValues(alpha: 0.2),
              blurRadius: size * 0.2,
              offset: Offset(0, size * 0.07),
            ),
          ],
        ),
        child: ClipOval(
          child: Image.memory(photoBytes, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      );
    }

    final preset = avatarPresetById(avatarId);
    final initials = name != null && name!.isNotEmpty
        ? name!.characters.first.toUpperCase()
        : '?';
    final bg = preset?.background ?? _brown;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: preset == null
            ? null
            : Border.all(color: Colors.white, width: size * 0.06),
        boxShadow: [
          BoxShadow(
            color: (preset == null ? _brown : const Color(0xFF3D2C1E))
                .withValues(alpha: 0.2),
            blurRadius: size * 0.2,
            offset: Offset(0, size * 0.07),
          ),
        ],
      ),
      child: Center(
        child: preset != null
            ? Text(preset.emoji, style: TextStyle(fontSize: size * 0.55, height: 1.1))
            : Text(
                initials,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.43,
                  fontWeight: FontWeight.w800,
                ),
              ),
      ),
    );
  }
}

/// 預設大頭貼的選擇格。
class AvatarPicker extends StatelessWidget {
  final String? selectedId;
  final ValueChanged<String> onSelected;

  /// 已選的自選照片（base64）。有照片時第一格顯示照片本身。
  final String? photo;

  /// 點「相簿」那格時呼叫；為 null 時不顯示這一格。
  final VoidCallback? onPickPhoto;

  const AvatarPicker({
    super.key,
    required this.selectedId,
    required this.onSelected,
    this.photo,
    this.onPickPhoto,
  });

  Widget _selectedBadge() => Positioned(
        right: 0,
        bottom: 0,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(color: _brown, shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
        ),
      );

  /// 第一格：從相簿選照片。選過就顯示那張照片，再點一次可以換一張。
  Widget _photoTile() {
    final selected = selectedId == photoAvatarId;
    final bytes = _photoBytes(photo);
    return Semantics(
      button: true,
      selected: selected,
      label: bytes == null ? '從相簿選擇照片' : '自選照片，點一下更換',
      child: GestureDetector(
        onTap: onPickPhoto,
        child: AnimatedScale(
          scale: selected ? 1.08 : 1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: const Color(0xFFF1ECE4),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? _brown : const Color(0xFFD9CFC2),
                width: selected ? 3 : 2,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (bytes != null)
                  Positioned.fill(
                    child: ClipOval(
                      child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
                    ),
                  )
                else
                  const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_a_photo_rounded, size: 24, color: _brown),
                      SizedBox(height: 2),
                      Text('相簿',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _brown)),
                    ],
                  ),
                if (selected) _selectedBadge(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _brown = Color(0xFF5C3D2E);

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: [
        if (onPickPhoto != null) _photoTile(),
        for (final p in avatarPresets)
          Semantics(
            button: true,
            selected: p.id == selectedId,
            label: '${p.label}大頭貼',
            child: GestureDetector(
              onTap: () => onSelected(p.id),
              child: AnimatedScale(
                scale: p.id == selectedId ? 1.08 : 1,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  decoration: BoxDecoration(
                    color: p.background,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: p.id == selectedId ? _brown : Colors.white,
                      width: p.id == selectedId ? 3 : 2,
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(p.emoji, style: const TextStyle(fontSize: 34, height: 1.1)),
                      if (p.id == selectedId) _selectedBadge(),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
