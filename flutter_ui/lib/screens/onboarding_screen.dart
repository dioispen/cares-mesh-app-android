import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  static const _bg = Color(0xFFF7F3EC);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  final FlutterTts _tts = FlutterTts();
  int _scene = 0;
  double _sceneOpacity = 0.0;
  bool _showStartBtn = false;
  bool _done = false;
  // 雙重門控：TTS 講完 + 最短顯示時間到，兩個都滿足才自動跳幕
  bool _ttsComplete = false;
  bool _minTimeReached = false;
  Timer? _minTimer;

  late final AnimationController _ctrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;
  late final AnimationController _talkCtrl; // 嘴巴開合

  late final Animation<double> _mascotEntrance; // 場景0：小助理從底部蹦出
  late final Animation<double> _zoomAnim;       // 場景2：鏡頭放大至右下角
  late final Animation<double> _waveAngle;
  late final Animation<double> _fadeA;
  late final Animation<double> _fadeB;
  late final Animation<double> _fadeC;
  late final Animation<double> _pulse;
  final List<Animation<double>> _cardFades = [];

  static const _scripts = [
    '嗨！我是你的防災小助理！很高興認識你！',
    '主畫面有六大功能，包括緊急求救、防空洞地圖、健康回報、防災知識、聊天室，還有物資捐贈，都是關鍵時刻最需要的工具！',
    '不管你在哪個畫面，我都會在右下角等你喔！',
    '有任何問題，點一下我，就知道怎麼解決！準備好了嗎？讓我們開始吧！',
  ];

  @override
  void initState() {
    super.initState();
    _initAnimations();
    // 必須等 TTS 完全初始化（包含 completion handler 設好）才跑第一幕
    _initTts().then((_) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _goScene(0));
      }
    });
  }

  Future<void> _initTts() async {
    _tts.setErrorHandler((msg) => debugPrint('TTS error: $msg'));

    // 找裝置上可用的中文語音：優先 zh-TW，找不到退回 zh-CN，再退回任何 zh-*
    try {
      final dynamic raw = await _tts.getLanguages;
      final List<String> langs =
          (raw as List?)?.map((e) => e.toString()).toList() ?? [];
      debugPrint('TTS available languages: $langs');

      String pick = 'zh-TW';
      if (langs.contains('zh-TW')) {
        pick = 'zh-TW';
      } else if (langs.contains('zh-CN')) {
        pick = 'zh-CN';
      } else {
        final any = langs.firstWhere(
          (l) => l.toLowerCase().startsWith('zh'),
          orElse: () => 'zh-TW',
        );
        pick = any;
      }
      await _tts.setLanguage(pick);
      debugPrint('TTS using language: $pick');
    } catch (e) {
      debugPrint('TTS getLanguages failed, defaulting to zh-TW: $e');
      await _tts.setLanguage('zh-TW');
    }

    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.1);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      if (!_done && mounted) {
        _ttsComplete = true;
        if (_minTimeReached) _tryAutoAdvance();
      }
    });
  }

  void _initAnimations() {
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);

    // 揮手：左右搖擺 ±12 度
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _waveAngle = Tween<double>(begin: -0.20, end: 0.20).animate(
      CurvedAnimation(parent: _waveCtrl, curve: Curves.easeInOut),
    );

    // 嘴巴開合：400ms 一循環
    _talkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    // 場景0：小助理從螢幕底部彈入，elasticOut 彈跳感
    _mascotEntrance = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.65, curve: Curves.elasticOut),
    );

    // 場景2：鏡頭從正常放大至右下角小助理位置
    _zoomAnim = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.55, 1.0, curve: Curves.easeInOut),
    );

    _fadeA = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.3, 0.7, curve: Curves.easeOut),
    );
    _fadeB = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.45, 0.85, curve: Curves.easeOut),
    );
    _fadeC = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.6, 1.0, curve: Curves.easeOut),
    );

    for (int i = 0; i < 6; i++) {
      final s = (0.15 + i * 0.1).clamp(0.0, 0.85);
      _cardFades.add(CurvedAnimation(
        parent: _ctrl,
        curve: Interval(s, (s + 0.3).clamp(0.0, 1.0), curve: Curves.easeOut),
      ));
    }

    _pulse = Tween<double>(begin: 0.88, end: 1.12).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  Future<void> _goScene(int s) async {
    if (!mounted || _done) return;
    _minTimer?.cancel();
    _ttsComplete = false;
    _minTimeReached = false;

    // Fade out
    setState(() => _sceneOpacity = 0.0);
    await Future.delayed(const Duration(milliseconds: 220));
    if (!mounted || _done) return;

    setState(() {
      _scene = s;
      _showStartBtn = false;
    });
    _ctrl
      ..reset()
      ..forward();
    setState(() => _sceneOpacity = 1.0);

    // 場景0：入場動畫快結束後才開始揮手
    if (s == 0) {
      Future.delayed(const Duration(milliseconds: 750), () {
        if (mounted && !_done) _waveCtrl.repeat(reverse: true);
      });
    } else {
      _waveCtrl.stop();
      _waveCtrl.reset();
    }

    // 場景2：TTS 開始後啟動嘴巴開合動畫
    if (s == 2) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && !_done && _scene == 2) _talkCtrl.repeat();
      });
    } else {
      _talkCtrl.stop();
      _talkCtrl.reset();
    }

    // 等動畫跑一下再開始 TTS
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted || _done) return;
    await _tts.speak(_scripts[s]);

    // 最短顯示時間：字數 × 200ms + 4秒緩衝，下限 8 秒，上限 18 秒
    final minMs = (_scripts[s].length * 200 + 4000).clamp(8000, 18000);
    _minTimer = Timer(Duration(milliseconds: minMs), () {
      if (!_done && mounted) {
        _minTimeReached = true;
        if (_ttsComplete) _tryAutoAdvance();
      }
    });
  }

  // 只有 TTS 講完 AND 最短時間到，才自動跳下一幕
  void _tryAutoAdvance() {
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (!_done && mounted && _ttsComplete && _minTimeReached) {
        if (_scene < 3) {
          _goScene(_scene + 1);
        } else {
          setState(() => _showStartBtn = true);
        }
      }
    });
  }

  // 手動下一幕（右箭頭按鈕）
  void _manualNext() {
    if (_done) return;
    _tts.stop();
    _minTimer?.cancel();
    if (_scene < 3) {
      _goScene(_scene + 1);
    } else {
      setState(() => _showStartBtn = true);
    }
  }

  // 手動返回上一幕（左箭頭按鈕）
  void _manualBack() {
    if (_done || _scene <= 0) return;
    _tts.stop();
    _minTimer?.cancel();
    _goScene(_scene - 1);
  }

  void _skip() {
    _done = true;
    _tts.stop();
    _minTimer?.cancel();
    _goHome();
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void dispose() {
    _done = true;
    _tts.stop();
    _minTimer?.cancel();
    _ctrl.dispose();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _talkCtrl.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Scene content with fade
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: _sceneOpacity,
              child: _buildScene(size),
            ),

            // Skip button (always visible)
            Positioned(
              top: 8,
              right: 12,
              child: TextButton(
                onPressed: _skip,
                child: Text(
                  '跳過',
                  style: TextStyle(
                    color: _brown.withValues(alpha: 0.5),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

            // 底部導航：← 點點 →
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    // 返回上一幕（第 0 幕隱藏）
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _scene > 0 ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: _scene <= 0,
                        child: IconButton(
                          onPressed: _manualBack,
                          icon: const Icon(Icons.arrow_back_ios_rounded),
                          color: _brown,
                          iconSize: 22,
                        ),
                      ),
                    ),
                    // 進度點
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                            4,
                            (i) => AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 4),
                                  width: _scene == i ? 24 : 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _scene == i
                                        ? _brown
                                        : _brown.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                )),
                      ),
                    ),
                    // 前往下一幕（顯示開始按鈕時隱藏）
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _showStartBtn ? 0.0 : 1.0,
                      child: IgnorePointer(
                        ignoring: _showStartBtn,
                        child: IconButton(
                          onPressed: _manualNext,
                          icon: const Icon(Icons.arrow_forward_ios_rounded),
                          color: _brown,
                          iconSize: 22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 開始使用按鈕（場景 3 TTS 結束後出現）
            AnimatedOpacity(
              duration: const Duration(milliseconds: 450),
              opacity: _showStartBtn ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_showStartBtn,
                child: Align(
                  alignment: const Alignment(0, 0.88),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _goHome,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _brown,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 4,
                          shadowColor: _brown.withValues(alpha: 0.3),
                        ),
                        child: const Text(
                          '開始使用  🚀',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
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

  Widget _buildScene(Size size) => switch (_scene) {
        0 => _buildScene0(size),
        1 => _buildScene1(size),
        2 => _buildScene2(size),
        _ => _buildScene3(size),
      };

  // ── Scene 0: 小助理從底部蹦出（大尺寸上半身） ──────────────────────────────

  Widget _buildScene0(Size size) {
    // 小助理圖片佔滿螢幕寬度，從底部往上蹦，只顯示上半身
    final mascotW = size.width;

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // 上方文字區
        Positioned(
          top: size.height * 0.09,
          left: 0,
          right: 0,
          child: Column(
            children: [
              FadeTransition(
                opacity: _fadeA,
                child: const Text(
                  '嗨！我是你的\n防災小助理 ✨',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    color: _textPrimary,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              FadeTransition(
                opacity: _fadeB,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    '很高興認識你！讓我帶你認識這個 APP 吧',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: _textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // 小助理：從螢幕底部以彈跳方式蹦出，只露出上半身
        AnimatedBuilder(
          animation: _mascotEntrance,
          builder: (_, child) {
            final t = _mascotEntrance.value;
            // 起點：完全藏在螢幕底部下方
            // 終點：從底部往上露出 ~55% 的身體（上半身）
            // 用 bottom 定位：負值代表超出螢幕底部
            final startBottom = -(mascotW * 1.05);
            final endBottom = -(mascotW * 0.45);
            final currentBottom =
                startBottom + (endBottom - startBottom) * t;
            return Positioned(
              bottom: currentBottom,
              left: 0,
              right: 0,
              child: child!,
            );
          },
          child: AnimatedBuilder(
            animation: _waveAngle,
            builder: (_, child) => Transform.rotate(
              angle: _waveAngle.value,
              // 從底部中心旋轉，讓揮手動作自然
              alignment: Alignment.bottomCenter,
              child: child,
            ),
            child: Image.asset(
              'assets/images/mascot_hi.png',
              width: mascotW,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Container(
                width: mascotW,
                height: mascotW,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _brown.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(mascotW / 2),
                ),
                child: Icon(Icons.support_agent_rounded,
                    size: mascotW * 0.45, color: _brown),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Scene 1: 六大功能介紹 ─────────────────────────────────────────────────

  Widget _buildScene1(Size size) {
    const features = [
      (Icons.sos_rounded, 'SOS 求救', Color(0xFFC4553A)),
      (Icons.auto_stories_rounded, '防災知識', Color(0xFF7AA67A)),
      (Icons.location_on_rounded, '防空洞地圖', Color(0xFF6B9EAD)),
      (Icons.favorite_rounded, '健康回報', Color(0xFFBF7A5A)),
      (Icons.chat_bubble_rounded, '聊天室', Color(0xFF9B88B3)),
      (Icons.volunteer_activism_rounded, '物資捐贈', Color(0xFF7AA67A)),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 80),
      child: Column(
        children: [
          // Mascot + speech bubble
          FadeTransition(
            opacity: _fadeA,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _mascotImg('assets/images/mascot_talking.png', 68),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Text(
                      '主畫面有六大功能，都是關鍵時刻最需要的工具！',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Feature cards — stagger fade-in
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.95,
            children: List.generate(features.length, (i) {
              final (icon, label, color) = features[i];
              return FadeTransition(
                opacity: _cardFades[i],
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: color, size: 24),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // ── Scene 2: 鏡頭放大至右下角小助理，嘴巴跟著動 ─────────────────────────

  Widget _buildScene2(Size size) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FadeTransition(
          opacity: _fadeA,
          child: const Text(
            '隨時找得到我',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: _textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        FadeTransition(
          opacity: _fadeA,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              '不管在哪個畫面，我都在右下角等你 👇',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: _textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),

        // 手機模型：先整體淡入，再鏡頭推向右下角小助理
        AnimatedBuilder(
          animation: _zoomAnim,
          builder: (_, child) {
            final z = _zoomAnim.value;
            // z: 0→1 時，縮放 1.0→2.4，焦點固定在右下角
            final scale = 1.0 + z * 1.4;
            return Transform.scale(
              scale: scale,
              alignment: Alignment.bottomRight,
              child: child,
            );
          },
          child: FadeTransition(
            opacity: _fadeB,
            child: _PhoneMockup(
              pulse: _pulse,
              size: size,
              talkAnim: _talkCtrl,
            ),
          ),
        ),
      ],
    );
  }

  // ── Scene 3: 示範點選小助理 ───────────────────────────────────────────────

  Widget _buildScene3(Size size) {
    const options = [
      ('🏠', '防空洞在哪裡？'),
      ('🆘', '怎麼求救？'),
      ('📋', '這個 APP 怎麼用？'),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 120),
      child: Column(
        children: [
          FadeTransition(
            opacity: _fadeA,
            child: const Text(
              '有問題？\n點我就知道！',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: _textPrimary,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(height: 28),

          FadeTransition(
            opacity: _fadeB,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Speech bubble with options
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(18),
                        topRight: Radius.circular(18),
                        bottomLeft: Radius.circular(18),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '嗨！我是你的防災小助理 ✨',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: _textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '有什麼需要幫助的嗎？',
                          style: TextStyle(
                            fontSize: 11,
                            color: _textSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...options.map((opt) => FadeTransition(
                              opacity: _fadeC,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 9),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF7F3EC),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: const Color(0xFFD4C5B0)),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(opt.$1,
                                          style:
                                              const TextStyle(fontSize: 15)),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          opt.$2,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                            color: _textPrimary,
                                          ),
                                        ),
                                      ),
                                      Icon(Icons.chevron_right_rounded,
                                          size: 15, color: _textSecondary),
                                    ],
                                  ),
                                ),
                              ),
                            )),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Mascot — pulsing to draw attention
                ScaleTransition(
                  scale: _pulse,
                  child: _mascotImg('assets/images/mascot_hi.png', 88),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper ────────────────────────────────────────────────────────────────

  Widget _mascotImg(String path, double size) {
    return Image.asset(
      path,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _brown.withValues(alpha: 0.08),
        ),
        child: Icon(Icons.support_agent_rounded,
            size: size * 0.55, color: _brown),
      ),
    );
  }
}

// ── Phone mockup (Scene 2) ────────────────────────────────────────────────────

class _PhoneMockup extends StatelessWidget {
  final Animation<double> pulse;
  final Size size;
  final AnimationController talkAnim;

  const _PhoneMockup({
    required this.pulse,
    required this.size,
    required this.talkAnim,
  });

  @override
  Widget build(BuildContext context) {
    final w = size.width * 0.56;
    final h = w * 1.95;

    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(w * 0.12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(w * 0.09),
          child: Stack(
            children: [
              // App screen mockup
              Container(
                color: const Color(0xFFF7F3EC),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // App bar
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      child: Row(
                        children: [
                          const Icon(Icons.shield_rounded,
                              color: Color(0xFFC4553A), size: 13),
                          const SizedBox(width: 4),
                          const Text(
                            '防災小助理',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF3D2C1E),
                            ),
                          ),
                          const Spacer(),
                          Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Color(0xFF5C3D2E),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Feature grid (simplified)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: GridView.count(
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: 2,
                          mainAxisSpacing: 5,
                          crossAxisSpacing: 5,
                          childAspectRatio: 1.05,
                          children: const [
                            Color(0xFFC4553A),
                            Color(0xFF7AA67A),
                            Color(0xFF6B9EAD),
                            Color(0xFFBF7A5A),
                          ]
                              .map((c) => ColoredBox(
                                    color: Colors.white,
                                    child: Center(
                                      child: Icon(Icons.widgets_rounded,
                                          color: Color.fromARGB(
                                              102,
                                              (c.r * 255).round(),
                                              (c.g * 255).round(),
                                              (c.b * 255).round()),
                                          size: 18),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 小助理：右下角脈衝光暈 + 嘴巴開合動畫
              Positioned(
                right: -4,
                bottom: 8,
                child: ScaleTransition(
                  scale: pulse,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 光暈背景
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFE8C99A).withValues(alpha: 0.5),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFE8C99A)
                                  .withValues(alpha: 0.7),
                              blurRadius: 12,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      // 嘴巴開合：talkAnim > 0.5 時切換至 talking 圖
                      AnimatedBuilder(
                        animation: talkAnim,
                        builder: (_, _) {
                          final isTalking = talkAnim.value > 0.5;
                          return Image.asset(
                            isTalking
                                ? 'assets/images/mascot_talking.png'
                                : 'assets/images/mascot_stand.png',
                            width: 34,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.support_agent_rounded,
                              size: 28,
                              color: Color(0xFF5C3D2E),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              // "我在這裡！" 標籤
              Positioned(
                right: 38,
                bottom: 24,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF5C3D2E),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '我在這裡！',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
