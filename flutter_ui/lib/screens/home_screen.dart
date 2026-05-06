import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'knowledge_screen.dart';
import 'shelter_screen.dart';
import 'sos_screen.dart';
import 'health_screen.dart';
import 'chat_screen.dart';
import 'login_screen.dart';
import 'supply_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final features = [
      {
        'title': 'SOS 緊急求救',
        'sub': '發送求救訊號',
        'icon': Icons.sos_rounded,
        'color': const Color(0xFFC4553A),
        'screen': const SOSScreen(),
      },
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
      {
        'title': '物資捐贈',
        'sub': '認領需求物資',
        'icon': Icons.volunteer_activism_rounded,
        'color': const Color(0xFF7AA67A),
        'screen': const SupplyScreen(),
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

            const SliverToBoxAdapter(child: SizedBox(height: 24)),
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
          const SizedBox(height: 20),

          // 登出按鈕
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('登出'),
                    content: const Text('確定要登出嗎？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('登出', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirm != true) return;

                await FirebaseAuth.instance.signOut();
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('app_user');

                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (_) => false,
                  );
                }
              },
              icon: const Icon(Icons.logout_rounded, color: Colors.red),
              label: const Text('登出', style: TextStyle(color: Colors.red, fontSize: 15)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
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
