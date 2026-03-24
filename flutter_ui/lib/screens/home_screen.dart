import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'knowledge_screen.dart';
import 'shelter_screen.dart';
import 'sos_screen.dart';
import 'health_screen.dart';
import 'chat_screen.dart';

const _prefsKeyUser = 'app_user';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _sosRed = Color(0xFFC4553A);

  AppUser? _user;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyUser);
    if (raw != null && mounted) {
      setState(() => _user = AppUser.fromJson(jsonDecode(raw)));
    }
  }

  void _showProfile() {
    if (_user == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ProfileSheet(user: _user!),
    );
  }

  // 目前狀態：0=安全, 1=需要協助, 2=緊急
  int _statusIndex = 0;

  static const _statusOptions = [
    {'label': '安全',    'color': Color(0xFF7AA67A), 'dotColor': Color(0xFF7AA67A), 'textColor': Color(0xFF4A7A4A), 'icon': Icons.check_circle_outline},
    {'label': '需要協助', 'color': Color(0xFFD4945A), 'dotColor': Color(0xFFD4945A), 'textColor': Color(0xFF8B4A00), 'icon': Icons.pan_tool_alt_outlined},
    {'label': '緊急',    'color': Color(0xFFC4553A), 'dotColor': Color(0xFFC4553A), 'textColor': Color(0xFFB52A10), 'icon': Icons.warning_amber_rounded},
  ];

  void _showStatusPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: const BoxDecoration(
          color: Color(0xFFFEFDF9),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            const Text('更新目前狀態', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF3D2C1E))),
            const SizedBox(height: 16),
            ..._statusOptions.asMap().entries.map((e) {
              final i = e.key;
              final opt = e.value;
              final isSelected = _statusIndex == i;
              return GestureDetector(
                onTap: () {
                  setState(() => _statusIndex = i);
                  Navigator.pop(context);
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isSelected ? (opt['color'] as Color).withValues(alpha: 0.12) : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected ? (opt['color'] as Color) : Colors.grey.shade200,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(opt['icon'] as IconData, color: opt['color'] as Color, size: 22),
                      const SizedBox(width: 12),
                      Text(opt['label'] as String,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: opt['textColor'] as Color)),
                      if (isSelected) ...[const Spacer(), Icon(Icons.check, color: opt['color'] as Color, size: 18)],
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final features = [
      {
        'title': '防災知識',
        'sub': '學習應急技能',
        'icon': Icons.auto_stories_rounded,
        'color': const Color(0xFF7AA67A),
        'screen': const KnowledgeScreen(),
      },
      {
        'title': '防空洞地圖',
        'sub': '附近避難所',
        'icon': Icons.location_on_rounded,
        'color': const Color(0xFF6B9EAD),
        'screen': const ShelterScreen(),
      },
      {
        'title': '健康回報',
        'sub': '回報您的狀況',
        'icon': Icons.favorite_rounded,
        'color': const Color(0xFFBF7A5A),
        'screen': const HealthScreen(),
      },
      {
        'title': '聊天室',
        'sub': '互助聯絡',
        'icon': Icons.chat_bubble_rounded,
        'color': const Color(0xFF9B88B3),
        'screen': const ChatScreen(),
      },
    ];

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // 手工感 AppBar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _sosRed.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.shield_rounded, color: _sosRed, size: 22),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '防災 APP',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: _textPrimary,
                        letterSpacing: 1,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _showProfile,
                      child: _UserAvatar(user: _user),
                    ),
                  ],
                ),
              ),
            ),

            // 歡迎語
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '平安是福',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: _textPrimary,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '做好準備，守護自己與家人',
                      style: TextStyle(fontSize: 14, color: _textSecondary),
                    ),
                    const SizedBox(height: 16),
                    // 狀態橫幅（可點擊）
                    GestureDetector(
                      onTap: _showStatusPicker,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: (_statusOptions[_statusIndex]['color'] as Color).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: (_statusOptions[_statusIndex]['color'] as Color).withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _statusOptions[_statusIndex]['dotColor'] as Color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '目前狀態：${_statusOptions[_statusIndex]['label']}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _statusOptions[_statusIndex]['textColor'] as Color,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '更新狀態 →',
                              style: TextStyle(
                                fontSize: 12,
                                color: (_statusOptions[_statusIndex]['color'] as Color).withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 功能卡片格
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 12),
                      child: Text(
                        '功能選單',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _textSecondary,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.05,
                      children: features.map((f) {
                        final color = f['color'] as Color;
                        return GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => f['screen'] as Widget),
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF3D2C1E).withValues(alpha: 0.06),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Stack(
                              children: [
                                // 右上角裝飾圓
                                Positioned(
                                  right: -14,
                                  top: -14,
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: color.withValues(alpha: 0.08),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: 0.14),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Icon(f['icon'] as IconData, color: color, size: 24),
                                      ),
                                      const Spacer(),
                                      Text(
                                        f['title'] as String,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: _textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        f['sub'] as String,
                                        style: TextStyle(fontSize: 11, color: _textSecondary),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),

            // SOS 按鈕
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SOSScreen()),
                  ),
                  child: Container(
                    height: 68,
                    decoration: BoxDecoration(
                      color: _sosRed,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: _sosRed.withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.sos_rounded, color: Colors.white, size: 26),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'SOS  緊急求救',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 右上角頭像 ────────────────────────────────────────────
class _UserAvatar extends StatelessWidget {
  final AppUser? user;
  const _UserAvatar({required this.user});

  @override
  Widget build(BuildContext context) {
    const brown = Color(0xFF5C3D2E);
    final initials = user != null && user!.name.isNotEmpty
        ? user!.name.characters.first.toUpperCase()
        : '?';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: brown,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: brown.withValues(alpha: 0.25),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: Text(
              initials,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        if (user != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              'ID',
              style: TextStyle(
                fontSize: 10,
                color: const Color(0xFF8C7B6E).withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

// ── 個人資料底部面板 ──────────────────────────────────────
class _ProfileSheet extends StatelessWidget {
  final AppUser user;
  const _ProfileSheet({required this.user});

  @override
  Widget build(BuildContext context) {
    const brown = Color(0xFF5C3D2E);
    const green = Color(0xFF7AA67A);
    const textPrimary = Color(0xFF3D2C1E);

    final initials = user.name.isNotEmpty
        ? user.name.characters.first.toUpperCase()
        : '?';

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
      decoration: const BoxDecoration(
        color: Color(0xFFFEFDF9),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖曳條
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 24),

          // 頭像 + 姓名 + ID
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: brown,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: brown.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Center(
              child: Text(initials,
                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(height: 12),
          Text(user.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: textPrimary)),
          const SizedBox(height: 6),

          // User ID 顯示 + 複製
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: user.id));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('User ID 已複製'),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  margin: const EdgeInsets.all(16),
                  backgroundColor: brown,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: brown.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fingerprint_rounded, size: 15, color: brown),
                  const SizedBox(width: 6),
                  Text(user.id,
                      style: const TextStyle(fontSize: 12, color: brown, fontWeight: FontWeight.w700,
                          fontFamily: 'monospace')),
                  const SizedBox(width: 6),
                  const Icon(Icons.copy_rounded, size: 13, color: brown),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // 基本資料
          _ProfileRow(Icons.phone_outlined, '手機號碼', user.phone),
          _ProfileRow(Icons.location_on_outlined, '居住區域', user.area),
          _ProfileRow(Icons.people_outline_rounded,
              '緊急聯絡人', '${user.emergencyContactName}（${user.emergencyContactRelation}）・${user.emergencyContactPhone}'),
          if (user.bloodType != null)
            _ProfileRow(Icons.favorite_outline_rounded, '血型', user.bloodType!),
          if (user.medicalInfo != null && user.medicalInfo!.isNotEmpty)
            _ProfileRow(Icons.medical_information_outlined, '醫療資訊', user.medicalInfo!),

          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 15, color: green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '此 ID 為你在防災系統中的唯一識別碼，管理端透過此 ID 識別你的身份',
                    style: const TextStyle(fontSize: 12, color: green),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _ProfileRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: const Color(0xFF8C7B6E)),
          const SizedBox(width: 10),
          SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: Color(0xFF8C7B6E))),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF3D2C1E))),
          ),
        ],
      ),
    );
  }
}
