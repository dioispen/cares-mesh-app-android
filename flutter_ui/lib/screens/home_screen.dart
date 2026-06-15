import 'dart:convert';
import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/mascot_service.dart';
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

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  static const _bg = Color(0xFFF7F3EC);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _sosRed = Color(0xFFC4553A);

  AppUser? _user;

  @override
  void initState() {
    super.initState();
    _loadUser();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) mascotOptionsNotifier.value = homeOptions;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    mascotRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    mascotRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPush() => mascotOptionsNotifier.value = homeOptions;

  @override
  void didPopNext() => mascotOptionsNotifier.value = homeOptions;

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

  void _navigateTo(Widget screen) {
    if (screen is SupplyScreen) mascotOptionsNotifier.value = const [];
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
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
        'title': '避難所地圖',
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
                      child: Image.asset('assets/images/logo.png', width: 32, height: 32),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '防災小助理：互CARES',
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
                      '平安是福，互CARES',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: _textPrimary,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '從「Who cares？」到「互 CARES」，讓每一個求助不被忽略',
                      style: TextStyle(fontSize: 14, color: _textSecondary),
                    ),
                  ],
                ),
              ),
            ),

            // 功能卡片
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    // SOS 大卡
                    _SosHeroCard(
                      onTap: () => _navigateTo(features[0]['screen'] as Widget),
                    ),
                    const SizedBox(height: 14),
                    // 防災知識 | 避難所地圖
                    Row(
                      children: [
                        Expanded(child: _FeatureCard(feature: features[1], featureIndex: 1, onTap: () => _navigateTo(features[1]['screen'] as Widget))),
                        const SizedBox(width: 12),
                        Expanded(child: _FeatureCard(feature: features[2], featureIndex: 2, onTap: () => _navigateTo(features[2]['screen'] as Widget))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 健康回報 | 聊天室
                    Row(
                      children: [
                        Expanded(child: _FeatureCard(feature: features[3], featureIndex: 3, onTap: () => _navigateTo(features[3]['screen'] as Widget))),
                        const SizedBox(width: 12),
                        Expanded(child: _FeatureCard(feature: features[4], featureIndex: 4, onTap: () => _navigateTo(features[4]['screen'] as Widget))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 物資捐贈（寬版）
                    _FeatureCardWide(
                      feature: features[5],
                      featureIndex: 5,
                      onTap: () => _navigateTo(features[5]['screen'] as Widget),
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

// ── SOS 緊急求救大卡 ──────────────────────────────────────────
class _SosHeroCard extends StatelessWidget {
  final VoidCallback onTap;
  const _SosHeroCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 22),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFD96048), Color(0xFFBF4530)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFC4553A).withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'SOS 緊急求救',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '一鍵傳送 GPS 位置・即刻求援',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.sos_rounded, color: Colors.white, size: 36),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 一般功能卡（正方形，2 欄格狀）────────────────────────────
class _FeatureCard extends StatelessWidget {
  final Map<String, Object?> feature;
  final int featureIndex;
  final VoidCallback onTap;
  const _FeatureCard({required this.feature, required this.featureIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = feature['color'] as Color;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFEFDF9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 彩色圖騰區
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: Container(
                height: 100,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      color.withValues(alpha: 0.18),
                      color.withValues(alpha: 0.08),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: CustomPaint(
                  painter: _FeatureIconPainter(featureIndex, color),
                ),
              ),
            ),
            // 文字區
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    feature['title'] as String,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3D2C1E),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    feature['sub'] as String,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF8C7B6E)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 寬版功能卡（橫向，用於物資捐贈）────────────────────────────
class _FeatureCardWide extends StatelessWidget {
  final Map<String, Object?> feature;
  final int featureIndex;
  final VoidCallback onTap;
  const _FeatureCardWide({required this.feature, required this.featureIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = feature['color'] as Color;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFFFEFDF9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            // 左側圖騰區
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
              child: Container(
                width: 90,
                height: 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      color.withValues(alpha: 0.18),
                      color.withValues(alpha: 0.08),
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
                child: CustomPaint(
                  painter: _FeatureIconPainter(featureIndex, color),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    feature['title'] as String,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3D2C1E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    feature['sub'] as String,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF8C7B6E)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Icon(
                Icons.chevron_right_rounded,
                color: const Color(0xFF8C7B6E).withValues(alpha: 0.5),
                size: 22,
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

// ── 功能圖騰 CustomPainter ────────────────────────────────────
class _FeatureIconPainter extends CustomPainter {
  final int index;
  final Color color;
  const _FeatureIconPainter(this.index, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    switch (index) {
      case 1: _paintKnowledge(canvas, size);
      case 2: _paintShelter(canvas, size);
      case 3: _paintHealth(canvas, size);
      case 4: _paintChat(canvas, size);
      case 5: _paintSupply(canvas, size);
    }
  }

  Paint _fill([Color? c]) =>
      Paint()..style = PaintingStyle.fill..color = c ?? color;

  Paint _stroke(Color c, double w) => Paint()
    ..style = PaintingStyle.stroke
    ..color = c
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _paintKnowledge(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 2;
    canvas.drawPath(
      Path()
        ..moveTo(cx - 1, cy - 22)
        ..lineTo(cx - 32, cy - 16)
        ..lineTo(cx - 32, cy + 20)
        ..lineTo(cx - 1, cy + 22)
        ..close(),
      _fill(color.withValues(alpha: 0.65)),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx + 1, cy - 22)
        ..lineTo(cx + 32, cy - 16)
        ..lineTo(cx + 32, cy + 20)
        ..lineTo(cx + 1, cy + 22)
        ..close(),
      _fill(),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy), width: 4, height: 44),
        const Radius.circular(2),
      ),
      _fill(color.withValues(alpha: 0.9)),
    );
    final lp = _stroke(Colors.white.withValues(alpha: 0.7), 2);
    for (int i = 0; i < 3; i++) {
      final y = cy - 8 + i * 8.0;
      canvas.drawLine(Offset(cx + 6, y), Offset(i == 2 ? cx + 20 : cx + 26, y), lp);
      canvas.drawLine(Offset(cx - 6, y), Offset(i == 2 ? cx - 20 : cx - 26, y), lp);
    }
  }

  void _paintShelter(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 4;
    final groundY = cy - 4.0;
    canvas.drawLine(Offset(cx - 38, groundY), Offset(cx + 38, groundY), _stroke(color, 2.5));
    final bunkerRect = Rect.fromCenter(center: Offset(cx, groundY), width: 54, height: 44);
    canvas.drawPath(
      Path()
        ..addArc(bunkerRect, math.pi, math.pi)
        ..lineTo(cx - 27, groundY)
        ..close(),
      _fill(color.withValues(alpha: 0.2)),
    );
    canvas.drawArc(bunkerRect, math.pi, math.pi, false, _stroke(color, 3));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, groundY + 15), width: 14, height: 18),
        const Radius.circular(3),
      ),
      _fill(),
    );
    final pinCy = groundY - 22;
    canvas.drawCircle(Offset(cx, pinCy), 8, _fill());
    canvas.drawCircle(Offset(cx, pinCy), 4, _fill(Colors.white));
    canvas.drawPath(
      Path()
        ..moveTo(cx - 6, pinCy + 4)
        ..lineTo(cx, pinCy + 18)
        ..lineTo(cx + 6, pinCy + 4)
        ..close(),
      _fill(),
    );
  }

  void _paintHealth(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 2;
    const s = 26.0;
    canvas.drawPath(
      Path()
        ..moveTo(cx, cy + s * 0.85)
        ..cubicTo(cx - s * 0.1, cy + s * 0.5, cx - s * 1.05, cy + s * 0.15, cx - s, cy - s * 0.25)
        ..cubicTo(cx - s, cy - s * 0.75, cx - s * 0.45, cy - s * 0.92, cx, cy - s * 0.45)
        ..cubicTo(cx + s * 0.45, cy - s * 0.92, cx + s, cy - s * 0.75, cx + s, cy - s * 0.25)
        ..cubicTo(cx + s * 1.05, cy + s * 0.15, cx + s * 0.1, cy + s * 0.5, cx, cy + s * 0.85)
        ..close(),
      _fill(),
    );
    for (final v in [true, false]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy - 4), width: v ? 10 : 26, height: v ? 26 : 10),
          const Radius.circular(2),
        ),
        _fill(Colors.white),
      );
    }
  }

  void _paintChat(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const r1 = Radius.circular(14);
    const r2 = Radius.circular(4);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromCenter(center: Offset(cx - 8, cy - 10), width: 54, height: 34),
        topLeft: r1, topRight: r1, bottomLeft: r2, bottomRight: r1,
      ),
      _fill(),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - 29, cy + 7)
        ..lineTo(cx - 43, cy + 20)
        ..lineTo(cx - 17, cy + 7)
        ..close(),
      _fill(),
    );
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromCenter(center: Offset(cx + 12, cy + 14), width: 38, height: 24),
        topLeft: r1, topRight: r1, bottomLeft: r1, bottomRight: r2,
      ),
      _fill(color.withValues(alpha: 0.5)),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx + 25, cy + 26)
        ..lineTo(cx + 39, cy + 36)
        ..lineTo(cx + 13, cy + 26)
        ..close(),
      _fill(color.withValues(alpha: 0.5)),
    );
    for (int i = -1; i <= 1; i++) {
      canvas.drawCircle(Offset(cx - 8 + i * 9.0, cy - 10), 3.5, _fill(Colors.white));
    }
  }

  void _paintSupply(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 4;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + 6), width: 46, height: 38),
        const Radius.circular(5),
      ),
      _fill(),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - 26, cy - 11)
        ..lineTo(cx - 23, cy - 20)
        ..lineTo(cx + 23, cy - 20)
        ..lineTo(cx + 26, cy - 11)
        ..close(),
      _fill(color.withValues(alpha: 0.8)),
    );
    canvas.drawLine(
      Offset(cx - 23, cy + 6), Offset(cx + 23, cy + 6),
      _stroke(Colors.white.withValues(alpha: 0.6), 2.5),
    );
    const hs = 8.0;
    final hx = cx, hy = cy + 10.0;
    canvas.drawPath(
      Path()
        ..moveTo(hx, hy + hs * 0.85)
        ..cubicTo(hx - hs * 0.1, hy + hs * 0.5, hx - hs * 1.05, hy + hs * 0.15, hx - hs, hy - hs * 0.25)
        ..cubicTo(hx - hs, hy - hs * 0.75, hx - hs * 0.45, hy - hs * 0.92, hx, hy - hs * 0.45)
        ..cubicTo(hx + hs * 0.45, hy - hs * 0.92, hx + hs, hy - hs * 0.75, hx + hs, hy - hs * 0.25)
        ..cubicTo(hx + hs * 1.05, hy + hs * 0.15, hx + hs * 0.1, hy + hs * 0.5, hx, hy + hs * 0.85)
        ..close(),
      _fill(Colors.white),
    );
  }

  @override
  bool shouldRepaint(_FeatureIconPainter old) =>
      old.index != index || old.color != color;
}
