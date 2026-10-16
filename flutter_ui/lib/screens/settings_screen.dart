import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bitchat_bridge.dart';
import '../models/profile_validation.dart';
import '../models/settings_state.dart';
import '../models/user.dart';
import '../services/account_service.dart';
import '../services/mascot_service.dart';
import '../services/profile_store.dart';
import '../services/settings_service.dart';
import '../widgets/user_avatar.dart';
import 'login_screen.dart';

const _bg = Color(0xFFF7F3EC);
const _card = Color(0xFFFEFDF9);
const _textPrimary = Color(0xFF3D2C1E);
const _textSecondary = Color(0xFF8C7B6E);
const _brown = Color(0xFF5C3D2E);
const _green = Color(0xFF7AA67A);
const _red = Color(0xFFC4553A);

/// 點首頁頭像開啟的設定頁（#80），取代原本的個人資料 bottom sheet。
///
/// 權限、藍牙與 mesh 背景運作的狀態都來自原生（[SettingsService]），每次從系統設定回到 App
/// （`resumed`）或系統狀態廣播時重新讀取。整頁可以捲動，小螢幕、大字體也不會 overflow（#79）。
///
/// [settings]、[profiles]、[account]、[signedOutBuilder] 只給測試注入替身。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.user,
    this.settings,
    this.profiles,
    this.account,
    this.signedOutBuilder,
  });

  final AppUser user;
  final SettingsService? settings;
  final ProfileStore? profiles;
  final AccountService? account;

  /// 登出或緊急清除後換上的畫面，預設為登入畫面。
  final WidgetBuilder? signedOutBuilder;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _SyncStatus { pending, synced, failed }

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsService _settings = widget.settings ?? SettingsService();
  late final ProfileStore _profiles = widget.profiles ?? ProfileStore();
  late final AccountService _account = widget.account ?? AccountService();

  late AppUser _user = widget.user;

  SettingsState? _state;
  Object? _stateError;

  /// 只採用最新一次讀取的結果，較早送出、較晚回來的不覆蓋它。
  int _stateRead = 0;

  late final AppLifecycleListener _lifecycle;
  StreamSubscription<void>? _statusChanges;

  bool _editing = false;
  _SyncStatus? _sync;
  Object? _syncError;

  /// 只有最近一次存檔的同步結果會更新 [_sync]。
  Object? _syncToken;

  bool _panicRunning = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // 事件串流出錯（例如沒有原生 event channel）時照樣顯示出來，狀態仍會在回到 App 時重新讀取。
    _statusChanges = _settings.systemStatusChanges.listen(
      (_) => _reload(),
      onError: (Object e) {
        if (mounted) setState(() => _stateError = e);
      },
    );
    _reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _statusChanges?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final read = ++_stateRead;
    try {
      final state = await _settings.loadState();
      if (!mounted || read != _stateRead) return;
      setState(() {
        _state = state;
        _stateError = null;
      });
    } catch (e) {
      if (!mounted || read != _stateRead) return;
      setState(() => _stateError = e);
    }
  }

  /// 把一個動作交給原生；失敗時告訴使用者。不論成敗都重新讀取狀態。
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _showSnackBar('操作失敗：${_describe(e)}');
    }
    await _reload();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      backgroundColor: _brown,
      duration: const Duration(seconds: 2),
    ));
  }

  static String _describe(Object error) => switch (error) {
        PlatformException(code: SettingsErrors.noActivity) => '目前無法開啟系統畫面',
        PlatformException(code: SettingsErrors.permissionRequired) => '請先允許「附近的裝置」權限',
        PlatformException(:final code, :final message) => message ?? code,
        _ => '$error',
      };

  // ── 大頭貼 ──────────────────────────────────────────────

  /// 本機先更新讓畫面立刻反映，Firestore 在背景寫入（離線時留在佇列，恢復連線再送出）。
  Future<void> _changeAvatar(String avatarId, String? photo) async {
    final updated = _user.withAvatar(avatarId, avatarPhoto: photo);
    setState(() => _user = updated);
    final sync = await _profiles.saveAvatar(updated);
    unawaited(sync.synced.catchError((Object e) => debugPrint('update avatar failed: $e')));
  }

  void _pickAvatar() {
    // 選照片失敗的原因直接寫在這個 sheet 裡：SnackBar 會被 sheet 擋住。
    String? pickError;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: const BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(height: 18),
                const Text('更換大頭貼',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _textPrimary)),
                const SizedBox(height: 18),
                if (pickError != null) ...[
                  _Notice(text: pickError!, color: Colors.red.shade700, icon: Icons.error_outline_rounded),
                  const SizedBox(height: 14),
                ],
                AvatarPicker(
                  selectedId: _user.avatar,
                  photo: _user.avatarPhoto,
                  onSelected: (id) {
                    _changeAvatar(id, null);
                    Navigator.pop(sheetContext);
                  },
                  onPickPhoto: () async {
                    final result = await pickAvatarPhoto();
                    if (!mounted || !sheetContext.mounted) return;
                    setSheetState(() => pickError = result.error);
                    final photo = result.photo;
                    if (photo == null) return;
                    _changeAvatar(photoAvatarId, photo);
                    Navigator.pop(sheetContext);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 個人資料 ────────────────────────────────────────────

  Future<void> _saveProfile(AppUser updated) async {
    final sync = await _profiles.saveProfile(updated);
    final token = Object();
    if (!mounted) {
      unawaited(sync.synced.catchError((Object e) => debugPrint('profile sync failed: $e')));
      return;
    }
    setState(() {
      _user = updated;
      _editing = false;
      _sync = _SyncStatus.pending;
      _syncError = null;
      _syncToken = token;
    });
    try {
      await sync.synced;
      if (mounted && _syncToken == token) setState(() => _sync = _SyncStatus.synced);
    } catch (e) {
      if (mounted && _syncToken == token) {
        setState(() {
          _sync = _SyncStatus.failed;
          _syncError = e;
        });
      }
    }
  }

  // ── 帳號 ────────────────────────────────────────────────

  void _goToSignedOut() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: widget.signedOutBuilder ?? (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('登出'),
        content: const Text('確定要登出嗎？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('登出', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _account.signOut();
    _goToSignedOut();
  }

  Future<void> _panicClear() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => const _PanicConfirmDialog());
    if (confirm != true || !mounted) return;

    setState(() => _panicRunning = true);
    try {
      await _account.panicClear();
    } on PanicSignOutFailed catch (e) {
      // 資料已經清掉了，不能讓使用者以為要重來一次。
      if (!mounted) return;
      setState(() => _panicRunning = false);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('資料已清除'),
          content: Text('本機資料已清除，但登出帳號失敗：${_describe(e.cause)}\n回到登入畫面後請重新登入。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('確定')),
          ],
        ),
      );
      _goToSignedOut();
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _panicRunning = false);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('清除未完成'),
          content: Text(switch (e) {
            PlatformException(code: SettingsErrors.panicIncomplete) =>
              '無法確認聊天紀錄已刪除，Mesh 已暫停運作。帳號與本機個人資料沒有清除，請再試一次。',
            PlatformException(code: SettingsErrors.panicInProgress) => '已經有一次清除正在進行，請稍候。',
            _ => '清除時發生錯誤：${_describe(e)}\n請再試一次。',
          }),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('確定')),
          ],
        ),
      );
      return;
    }
    _goToSignedOut();
  }

  // ── 畫面 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        surfaceTintColor: _bg,
        foregroundColor: _textPrimary,
        title: const Text('設定', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            _ProfileCard(user: _user, onAvatarTap: _pickAvatar, onIdCopied: () => _showSnackBar('User ID 已複製')),
            if (_stateError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _Notice(
                  text: '無法讀取系統狀態：$error',
                  color: _red,
                  icon: Icons.error_outline_rounded,
                  action: TextButton(onPressed: _reload, child: const Text('重試')),
                ),
              ),
            if (_state case final state?) ...[
              _Section(title: '權限與系統', children: [
                for (final permission in state.permissions)
                  _PermissionTile(
                    permission: permission,
                    onTap: () => _run(() => _settings.requestPermission(permission.category)),
                  ),
                _BluetoothTile(
                  enabled: state.bluetoothEnabled,
                  onRequestEnable: () => _run(_settings.requestEnableBluetooth),
                ),
              ]),
              _Section(title: 'Mesh 背景運作', children: [
                _SwitchTile(
                  title: '背景執行',
                  subtitle: '離開 App 後仍維持 Mesh 連線與轉送。關閉時會停止前景服務。',
                  value: state.backgroundEnabled,
                  onChanged: (v) => _run(() => _settings.setBackgroundEnabled(v)),
                ),
                _SwitchTile(
                  title: '開機自動啟動',
                  subtitle: '手機開機後自動開始 Mesh 服務。',
                  value: state.autoStartEnabled,
                  onChanged: (v) => _run(() => _settings.setAutoStartEnabled(v)),
                ),
                if (state.backgroundEnabled)
                  _SwitchTile(
                    title: '常駐通知被滑掉時立即恢復',
                    subtitle: 'Android 14 起可以滑掉常駐通知，平常回到 App 時才會重新出現；開啟後，滑掉就馬上重新出現。',
                    value: state.notificationAutoRestore,
                    onChanged: (v) => _run(() => _settings.setNotificationAutoRestore(v)),
                  ),
              ]),
            ],
            _Section(title: '個人資料', children: [
              if (_editing)
                _ProfileEditor(
                  user: _user,
                  onSave: _saveProfile,
                  onCancel: () => setState(() => _editing = false),
                )
              else
                _ProfileDetails(
                  user: _user,
                  sync: _sync,
                  syncError: _syncError,
                  onEdit: () => setState(() => _editing = true),
                ),
            ]),
            _Section(title: '顯示', children: [
              ValueListenableBuilder<bool>(
                valueListenable: mascotEnabledNotifier,
                builder: (context, enabled, _) => _SwitchTile(
                  title: '顯示小助理',
                  subtitle: '畫面右下角的防災小助理。',
                  value: enabled,
                  onChanged: setMascotEnabled,
                ),
              ),
            ]),
            _Section(title: '帳號與資料', children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _panicRunning ? null : _signOut,
                      icon: const Icon(Icons.logout_rounded, color: Colors.red),
                      label: const Text('登出', style: TextStyle(color: Colors.red, fontSize: 15)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _panicRunning ? null : _panicClear,
                      icon: _panicRunning
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.delete_forever_rounded),
                      label: const Text('緊急清除資料', style: TextStyle(fontSize: 15)),
                      style: FilledButton.styleFrom(
                        backgroundColor: _red,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '清除本機的聊天紀錄、身分金鑰、媒體檔與通知，並登出帳號。雲端上的資料不會刪除。',
                      style: TextStyle(fontSize: 12, color: _textSecondary),
                    ),
                  ],
                ),
              ),
            ]),
            _Section(title: '關於', children: [
              ListTile(
                leading: const Icon(Icons.info_outline_rounded, color: _textSecondary),
                title: const Text('版本', style: TextStyle(color: _textPrimary)),
                trailing: Text(_state?.appVersion ?? '—', style: const TextStyle(color: _textSecondary)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ── 個人資料卡 ──────────────────────────────────────────────

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.user, required this.onAvatarTap, required this.onIdCopied});

  final AppUser user;
  final VoidCallback onAvatarTap;
  final VoidCallback onIdCopied;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          GestureDetector(
            onTap: onAvatarTap,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                UserAvatarCircle(avatarId: user.avatar, photo: user.avatarPhoto, name: user.name, size: 76),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: _brown,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.edit_rounded, size: 13, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(user.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _textPrimary)),
          const SizedBox(height: 6),
          GestureDetector(
            key: const Key('settings_copy_user_id'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: user.id));
              onIdCopied();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _brown.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fingerprint_rounded, size: 15, color: _brown),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(user.id,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: _brown, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.copy_rounded, size: 13, color: _brown),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _Notice(
            text: '此 ID 為你在防災系統中的唯一識別碼，管理端透過此 ID 識別你的身份',
            color: _green,
            icon: Icons.info_outline_rounded,
          ),
        ],
      ),
    );
  }
}

// ── 權限與系統 ──────────────────────────────────────────────

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({required this.permission, required this.onTap});

  final SettingsPermissionStatus permission;
  final VoidCallback onTap;

  static IconData _icon(SettingsPermissionCategory category) => switch (category) {
        SettingsPermissionCategory.location => Icons.location_on_rounded,
        SettingsPermissionCategory.backgroundLocation => Icons.my_location_rounded,
        SettingsPermissionCategory.nearbyDevices => Icons.bluetooth_searching_rounded,
        SettingsPermissionCategory.notifications => Icons.notifications_rounded,
        SettingsPermissionCategory.batteryOptimization => Icons.battery_charging_full_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final battery = permission.category == SettingsPermissionCategory.batteryOptimization;
    final status = switch ((battery, permission.granted)) {
      (true, true) => '已排除',
      (true, false) => '未排除',
      (false, true) => '已允許',
      (false, false) => '未允許',
    };
    return ListTile(
      leading: Icon(_icon(permission.category), color: _textSecondary),
      title: Text(permission.category.label, style: const TextStyle(color: _textPrimary)),
      subtitle: Text(status, style: TextStyle(color: permission.granted ? _green : _red, fontWeight: FontWeight.w600)),
      trailing: const Icon(Icons.chevron_right_rounded, color: _textSecondary),
      onTap: onTap,
    );
  }
}

class _BluetoothTile extends StatelessWidget {
  const _BluetoothTile({required this.enabled, required this.onRequestEnable});

  final bool enabled;
  final VoidCallback onRequestEnable;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(enabled ? Icons.bluetooth_rounded : Icons.bluetooth_disabled_rounded, color: _textSecondary),
      title: const Text('藍牙', style: TextStyle(color: _textPrimary)),
      subtitle: Text(enabled ? '已開啟' : '已關閉',
          style: TextStyle(color: enabled ? _green : _red, fontWeight: FontWeight.w600)),
      trailing: enabled ? null : TextButton(onPressed: onRequestEnable, child: const Text('開啟藍牙')),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({required this.title, required this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: _textPrimary)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: _textSecondary)),
      value: value,
      activeThumbColor: _green,
      onChanged: onChanged,
    );
  }
}

// ── 個人資料 ────────────────────────────────────────────────

class _ProfileDetails extends StatelessWidget {
  const _ProfileDetails({required this.user, required this.sync, required this.syncError, required this.onEdit});

  final AppUser user;
  final _SyncStatus? sync;
  final Object? syncError;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InfoRow('姓名', user.name),
          _InfoRow('Email', user.email ?? '—'),
          _InfoRow('User ID', user.id),
          _InfoRow('手機號碼', user.phone),
          _InfoRow('居住區域', user.area),
          _InfoRow('緊急聯絡人',
              '${user.emergencyContactName}（${user.emergencyContactRelation}）・${user.emergencyContactPhone}'),
          _InfoRow('血型', user.bloodType ?? '未填'),
          _InfoRow('醫療資訊', (user.medicalInfo?.isNotEmpty ?? false) ? user.medicalInfo! : '未填'),
          if (sync case final status?) ...[
            const SizedBox(height: 8),
            switch (status) {
              _SyncStatus.pending => const _Notice(
                  text: '已存在本機，尚未同步到雲端。連上網路後會自動同步。',
                  color: _brown,
                  icon: Icons.cloud_upload_outlined,
                ),
              _SyncStatus.synced => const _Notice(
                  text: '已儲存，並已同步到雲端。',
                  color: _green,
                  icon: Icons.cloud_done_outlined,
                ),
              _SyncStatus.failed => _Notice(
                  text: '已存在本機，但雲端同步失敗：$syncError',
                  color: _red,
                  icon: Icons.cloud_off_outlined,
                ),
            },
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_rounded, color: _brown),
            label: const Text('編輯個人資料', style: TextStyle(color: _brown)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _brown),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.user, required this.onSave, required this.onCancel});

  final AppUser user;
  final Future<void> Function(AppUser updated) onSave;
  final VoidCallback onCancel;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.name);
  late final _phone = TextEditingController(text: widget.user.phone);
  late final _area = TextEditingController(text: widget.user.area);
  late final _contactName = TextEditingController(text: widget.user.emergencyContactName);
  late final _contactRelation = TextEditingController(text: widget.user.emergencyContactRelation);
  late final _contactPhone = TextEditingController(text: widget.user.emergencyContactPhone);
  late final _medical = TextEditingController(text: widget.user.medicalInfo ?? '');
  late String? _bloodType = widget.user.bloodType;
  bool _saving = false;

  @override
  void dispose() {
    for (final controller in [_name, _phone, _area, _contactName, _contactRelation, _contactPhone, _medical]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final medical = _medical.text.trim();
    try {
      await widget.onSave(widget.user.withProfile(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        area: _area.text.trim(),
        emergencyContactName: _contactName.text.trim(),
        emergencyContactPhone: _contactPhone.text.trim(),
        emergencyContactRelation: _contactRelation.text.trim(),
        bloodType: _bloodType,
        medicalInfo: medical.isEmpty ? null : medical,
      ));
    } catch (e) {
      // 本機副本寫不進去：表單留著，使用者輸入的內容不會不見。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('儲存失敗：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    FormFieldValidator<String>? validator,
    bool phone = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        validator: validator,
        maxLines: maxLines,
        keyboardType: phone ? TextInputType.phone : null,
        inputFormatters: phone ? [FilteringTextInputFormatter.allow(ProfileValidation.phoneCharacters)] : null,
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InfoRow('Email', widget.user.email ?? '—'),
            _InfoRow('User ID', widget.user.id),
            const SizedBox(height: 12),
            _field('姓名', _name, validator: ProfileValidation.name),
            _field('手機號碼', _phone, validator: ProfileValidation.phone, phone: true),
            _field('居住區域', _area, validator: ProfileValidation.area),
            _field('緊急聯絡人姓名', _contactName, validator: ProfileValidation.emergencyContactName),
            _field('與你的關係', _contactRelation, validator: ProfileValidation.emergencyContactRelation),
            _field('緊急聯絡人電話', _contactPhone, validator: ProfileValidation.emergencyContactPhone, phone: true),
            const Text('血型', style: TextStyle(fontSize: 13, color: _textSecondary)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in ProfileValidation.bloodTypes)
                  ChoiceChip(
                    label: Text(type),
                    selected: _bloodType == type,
                    onSelected: (selected) => setState(() => _bloodType = selected ? type : null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _field('慢性病 / 藥物過敏', _medical, maxLines: 3),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : widget.onCancel,
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: _brown),
                    child: const Text('儲存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── 帳號與資料 ──────────────────────────────────────────────

/// 緊急清除的二次確認：輸入「清除」才能按下。
class _PanicConfirmDialog extends StatefulWidget {
  const _PanicConfirmDialog();

  @override
  State<_PanicConfirmDialog> createState() => _PanicConfirmDialogState();
}

class _PanicConfirmDialogState extends State<_PanicConfirmDialog> {
  static const _confirmWord = '清除';
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('緊急清除資料'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('將清除本機的聊天紀錄、身分金鑰、媒體檔與通知，並登出帳號、回到登入畫面。'
                '清除後換成新的身分，無法復原。雲端上的資料不會刪除。'),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: '輸入「$_confirmWord」確認'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          onPressed: _input.text.trim() == _confirmWord ? () => Navigator.pop(context, true) : null,
          style: FilledButton.styleFrom(backgroundColor: _red),
          child: const Text(_confirmWord),
        ),
      ],
    );
  }
}

// ── 共用 ────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _textSecondary)),
          ),
          Material(
            color: _card,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: const TextStyle(fontSize: 13, color: _textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _textPrimary)),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color, required this.icon, this.action});

  final String text;
  final Color color;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
          ?action,
        ],
      ),
    );
  }
}
