import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../services/mascot_service.dart';
import 'knowledge_detail_screen.dart';

class KnowledgeScreen extends StatefulWidget {
  const KnowledgeScreen({super.key});

  @override
  State<KnowledgeScreen> createState() => _KnowledgeScreenState();
}

// ─── Data model ───────────────────────────────────────────────────────────────

class _BubbleTopic {
  final String category;
  final String imagePath;
  final Color color;
  final List<String> tips;
  final List<TipSection> sections;
  final List<VideoItem> videos;

  double x, y, dx, dy;
  final double size;

  _BubbleTopic({
    required this.category,
    required this.imagePath,
    required this.color,
    this.tips = const [],
    this.sections = const [],
    this.videos = const [],
    required this.x,
    required this.y,
    required this.dx,
    required this.dy,
    this.size = 160,
  });

  void update(double maxX, double maxY) {
    x += dx;
    y += dy;
    if (x < 0) {
      x = 0;
      dx = dx.abs();
    } else if (x > maxX) {
      x = maxX;
      dx = -dx.abs();
    }
    if (y < 0) {
      y = 0;
      dy = dy.abs();
    } else if (y > maxY) {
      y = maxY;
      dy = -dy.abs();
    }
  }
}

// ─── Screen state ─────────────────────────────────────────────────────────────

class _KnowledgeScreenState extends State<KnowledgeScreen>
    with SingleTickerProviderStateMixin, RouteAware {
  late Ticker _ticker;
  List<_BubbleTopic>? _bubbles;
  Size _canvasSize = Size.zero;

  static final _topicsData = [
    (
      category: '地震',
      imagePath: 'assets/images/knowledge/earthquake.png',
      color: const Color(0xFFBF7A5A),
      tips: const [
        '保持冷靜，立即蹲下、掩護、抓穩',
        '遠離窗戶、玻璃和可能倒塌的物品',
        '如在室內，躲在桌子下或靠近承重牆',
        '不要使用電梯逃生',
        '震後注意餘震，檢查瓦斯是否外洩',
      ],
      sections: const <TipSection>[],
      videos: const [VideoItem(label: '', path: 'assets/videos/earthquake.mp4')],
    ),
    (
      category: '颱風',
      imagePath: 'assets/images/knowledge/typhoon.png',
      color: const Color(0xFF6B9EAD),
      tips: const [
        '提前儲備食物、飲水和藥品',
        '關好門窗，將室外物品搬入室內',
        '遠離海岸、河川及低窪地區',
        '收聽氣象預報，遵從政府疏散指令',
        '停電時使用手電筒，避免使用蠟燭',
      ],
      sections: const <TipSection>[],
      videos: const [VideoItem(label: '', path: 'assets/videos/typhoon.mp4')],
    ),
    (
      category: '洪水',
      imagePath: 'assets/images/knowledge/flood.png',
      color: const Color(0xFF5E8FA3),
      tips: const [
        '立即前往高處避難，不要等待',
        '不要嘗試徒步涉水，水流可能很急',
        '關閉電源總開關，防止觸電',
        '攜帶重要文件和緊急物資撤離',
        '等待官方宣布安全後才返回',
      ],
      sections: const <TipSection>[],
      videos: const [VideoItem(label: '', path: 'assets/videos/flood.mp4')],
    ),
    (
      category: '火災',
      imagePath: 'assets/images/knowledge/fire.png',
      color: const Color(0xFFCC6B4A),
      tips: const [
        '立即撥打119報警',
        '低姿勢爬行，避免吸入濃煙',
        '用濕毛巾捂住口鼻',
        '不要搭乘電梯逃生，走安全梯',
        '逃出後不要回頭取物，在外等待救援',
      ],
      sections: const <TipSection>[],
      videos: const [VideoItem(label: '', path: 'assets/videos/fire.mp4')],
    ),
    (
      category: '緊急物資',
      imagePath: 'assets/images/knowledge/supplies.png',
      color: const Color(0xFF7AA67A),
      tips: const [
        '飲用水（每人每天至少 2 公升，備 3 天份）',
        '乾糧（餅乾、罐頭等不易腐敗食物）',
        '急救藥品和個人長期用藥',
        '手電筒和備用電池',
        '重要文件影本（身分證、健保卡）',
        '備用行動電源或充電器',
        '現金（停電時電子支付可能失效）',
      ],
      sections: const <TipSection>[],
      videos: const [VideoItem(label: '', path: 'assets/videos/supplies.mp4')],
    ),
    (
      category: '緊急電話',
      imagePath: 'assets/images/knowledge/contacts.png',
      color: const Color(0xFF9B88B3),
      tips: const [
        '緊急救援：119',
        '警察報案：110',
        '災害應變中心：1991',
        '衛生福利部安心專線：1925',
        '全國災害防救專線：0800-000-911',
      ],
      sections: const <TipSection>[],
      videos: const <VideoItem>[],
    ),
    (
      category: '急救知識',
      imagePath: 'assets/images/knowledge/firstaid.png',
      color: const Color(0xFFC05050),
      tips: const <String>[],
      sections: const [
        TipSection(
          header: '🫀 無意識／CPR＋AED',
          tips: [
            '確認當事人有無反應及呼吸',
            '立刻呼救並撥打 119',
            '進行 CPR 胸部按壓：雙手交扣、手臂打直、以掌根垂直下壓，每分鐘 100–120 下，至少 5 公分深',
            '使用 AED：打開電源，依照語音指示操作',
            '持續急救直到救護人員抵達',
          ],
        ),
        TipSection(
          header: '🩸 大量出血',
          tips: [
            '立刻撥打 119',
            '對傷口直接加壓止血',
            '若有止血帶：綁在出血點上方 5–8 公分，並記錄開始使用時間',
            '若無止血帶：用衣物或毛巾加壓，或用圍巾、絲巾搭配長棍作為臨時止血帶',
          ],
        ),
        TipSection(
          header: '🔥 燒燙傷（沖脫泡蓋送）',
          tips: [
            '沖：大量乾淨冷水沖洗傷口',
            '脫：去除傷口部位衣物',
            '泡：持續以冷水浸泡傷口',
            '蓋：用乾淨毛巾或紗布覆蓋',
            '送：盡快就醫',
          ],
        ),
        TipSection(
          header: '☣️ 毒化物質災害（避脫沖蓋送）',
          tips: [
            '避：用手帕或濕布遮住口鼻，往上風方向離開',
            '脫：到達安全區域後脫去外衣及遮蔽物',
            '沖：先用乾布擦去汙染物，再用大量清水從頭到腳沖洗',
            '蓋：用乾淨外衣覆蓋，注意保暖',
            '送：立即就醫或送醫',
          ],
        ),
        TipSection(
          header: '☢️ 核子事故（停看聽）',
          tips: [
            '停：立即進入室內，關閉門窗',
            '看：打開電視或收音機，注意政府資訊',
            '聽：遵從政府指示，如疏散或服用碘片（請勿擅自服用）',
          ],
        ),
      ],
      videos: const [
        VideoItem(label: '', path: 'assets/videos/firstaid_1.mp4'),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    mascotRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void didPush() => mascotOptionsNotifier.value = knowledgeOptions;

  @override
  void didPopNext() => mascotOptionsNotifier.value = knowledgeOptions;

  List<_BubbleTopic> _buildBubbles(Size size) {
    final rand = Random();
    const bubbleSize = 160.0;
    final speeds = [0.42, 0.60, 0.50, 0.72, 0.55, 0.65, 0.58];

    return _topicsData.asMap().entries.map((entry) {
      final i = entry.key;
      final t = entry.value;
      final angle = rand.nextDouble() * 2 * pi;
      return _BubbleTopic(
        category: t.category,
        imagePath: t.imagePath,
        color: t.color,
        tips: List<String>.from(t.tips),
        sections: t.sections,
        videos: t.videos,
        x: rand.nextDouble() * (size.width - bubbleSize),
        y: rand.nextDouble() * (size.height - bubbleSize),
        dx: cos(angle) * speeds[i],
        dy: sin(angle) * speeds[i],
        size: bubbleSize,
      );
    }).toList();
  }

  void _onTick(Duration _) {
    final bubbles = _bubbles;
    if (bubbles == null || _canvasSize == Size.zero) return;
    setState(() {
      for (final b in bubbles) {
        b.update(_canvasSize.width - b.size, _canvasSize.height - b.size);
      }
      _resolveBubbleCollisions(bubbles);
    });
  }

  void _resolveBubbleCollisions(List<_BubbleTopic> bubbles) {
    for (int i = 0; i < bubbles.length; i++) {
      for (int j = i + 1; j < bubbles.length; j++) {
        final a = bubbles[i];
        final b = bubbles[j];
        final ax = a.x + a.size / 2;
        final ay = a.y + a.size / 2;
        final bx = b.x + b.size / 2;
        final by = b.y + b.size / 2;
        final dx = bx - ax;
        final dy = by - ay;
        final distSq = dx * dx + dy * dy;
        final minDist = (a.size + b.size) / 2;
        if (distSq < minDist * minDist && distSq > 0) {
          final dist = sqrt(distSq);
          final nx = dx / dist;
          final ny = dy / dist;
          final dvx = a.dx - b.dx;
          final dvy = a.dy - b.dy;
          final dot = dvx * nx + dvy * ny;
          if (dot > 0) {
            a.dx -= dot * nx;
            a.dy -= dot * ny;
            b.dx += dot * nx;
            b.dy += dot * ny;
          }
          final overlap = (minDist - dist) / 2;
          a.x -= overlap * nx;
          a.y -= overlap * ny;
          b.x += overlap * nx;
          b.y += overlap * ny;
        }
      }
    }
  }

  @override
  void dispose() {
    mascotRouteObserver.unsubscribe(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F3EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F3EC),
        title: const Text(
          '防災知識',
          style: TextStyle(
              color: Color(0xFF3D2C1E), fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF3D2C1E)),
        centerTitle: false,
        elevation: 0,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (_bubbles == null) {
            _canvasSize = size;
            _bubbles = _buildBubbles(size);
          } else {
            _canvasSize = size;
          }

          final bubbles = _bubbles!;
          return Stack(
            children: [
              // Background gradient
              Container(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0.2, -0.3),
                    radius: 1.4,
                    colors: [Color(0xFFFEFDF9), Color(0xFFEDE7DA)],
                  ),
                ),
              ),
              // Disaster-themed background pattern
              const _DisasterPattern(),
              // Floating bubbles
              ...bubbles.map(
                (bubble) => Positioned(
                  left: bubble.x,
                  top: bubble.y,
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => KnowledgeDetailScreen(
                          category: bubble.category,
                          imagePath: bubble.imagePath,
                          color: bubble.color,
                          tips: bubble.tips,
                          sections: bubble.sections,
                          videos: bubble.videos,
                        ),
                      ),
                    ),
                    child: _BubbleWidget(bubble: bubble),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Background pattern ───────────────────────────────────────────────────────

class _DisasterPattern extends StatelessWidget {
  const _DisasterPattern();

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: CustomPaint(painter: _PatternPainter()),
    );
  }
}

class _PatternPainter extends CustomPainter {
  // Icons representing each disaster type
  static const _icons = [
    Icons.terrain_rounded,           // earthquake
    Icons.cyclone_rounded,           // typhoon
    Icons.water_rounded,             // flood
    Icons.local_fire_department_rounded, // fire
    Icons.warning_amber_rounded,     // general warning
    Icons.waves_rounded,             // waves
    Icons.air_rounded,               // wind
    Icons.shield_rounded,            // protection
    Icons.emergency_rounded,         // emergency
    Icons.water_drop_outlined,       // water drop
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rand = Random(7); // fixed seed = consistent layout
    // Warm tan — darker than bg (#F7F3EC) but same hue family
    const patternColor = Color(0xFFC8B89A);

    for (int i = 0; i < 30; i++) {
      final icon = _icons[rand.nextInt(_icons.length)];
      final x = rand.nextDouble() * size.width;
      final y = rand.nextDouble() * size.height;
      final iconSize = 22.0 + rand.nextDouble() * 20;
      final rotation = (rand.nextDouble() - 0.5) * pi / 2;

      final tp = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: iconSize,
            fontFamily: icon.fontFamily,
            color: patternColor,
          ),
        )
        ..layout();

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rotation);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) => false;
}

// ─── Bubble widget ────────────────────────────────────────────────────────────

class _BubbleWidget extends StatelessWidget {
  final _BubbleTopic bubble;
  const _BubbleWidget({required this.bubble});

  @override
  Widget build(BuildContext context) {
    final s = bubble.size;
    final color = bubble.color;

    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          // Coloured ambient glow
          BoxShadow(
            color: color.withValues(alpha: 0.38),
            blurRadius: 28,
            spreadRadius: 4,
            offset: const Offset(0, 6),
          ),
          // Soft drop shadow
          BoxShadow(
            color: const Color(0xFF3D2C1E).withValues(alpha: 0.12),
            blurRadius: 12,
            spreadRadius: -2,
            offset: const Offset(0, 4),
          ),
          // Subtle inner-edge white halo (simulated with negative spread)
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.7),
            blurRadius: 6,
            spreadRadius: -10,
          ),
        ],
      ),
      child: Stack(
        children: [
          // ① Clipped image + internal glass layers
          ClipOval(
            child: Stack(
              children: [
                // Image
                SizedBox(
                  width: s,
                  height: s,
                  child: Image.asset(
                    bubble.imagePath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(colors: [
                          color.withValues(alpha: 0.45),
                          color.withValues(alpha: 0.15),
                        ]),
                      ),
                      child: Icon(Icons.image_not_supported_outlined,
                          color: color, size: s * 0.35),
                    ),
                  ),
                ),

                // Subtle colour wash to unify image with theme colour
                Positioned.fill(
                  child: Container(
                    color: color.withValues(alpha: 0.06),
                  ),
                ),

                // Bottom darkness — adds depth / curvature sense
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: s * 0.38,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.50),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // Label text
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      bubble.category,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        shadows: [
                          Shadow(blurRadius: 6, color: Colors.black)
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Glass layers ──────────────────────────────────────────

                // Wide diffuse top highlight
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: s * 0.52,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.38),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 1.0],
                      ),
                    ),
                  ),
                ),

                // Specular highlight — small bright oval top-left
                // This is the #1 cue that makes something look like glass
                Positioned(
                  top: s * 0.07,
                  left: s * 0.13,
                  child: Container(
                    width: s * 0.36,
                    height: s * 0.19,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.all(
                          Radius.elliptical(s * 0.36, s * 0.19)),
                      gradient: RadialGradient(
                        center: Alignment.center,
                        colors: [
                          Colors.white.withValues(alpha: 0.92),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),

                // Tiny secondary specular dot — adds sparkle
                Positioned(
                  top: s * 0.14,
                  left: s * 0.54,
                  child: Container(
                    width: s * 0.10,
                    height: s * 0.06,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.all(
                          Radius.elliptical(s * 0.10, s * 0.06)),
                      color: Colors.white.withValues(alpha: 0.65),
                    ),
                  ),
                ),

                // Left-side catch light — thin vertical crescent
                Positioned(
                  top: s * 0.22,
                  left: s * 0.04,
                  child: Container(
                    width: s * 0.06,
                    height: s * 0.28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(s * 0.06),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.5),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ② Rim ring — drawn outside ClipOval so it's not cut
          Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.45),
                width: 2.0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
