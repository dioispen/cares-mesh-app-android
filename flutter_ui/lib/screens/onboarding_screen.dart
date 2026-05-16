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

  // ★ 把這個數值改成你的 GIF 實際時長（毫秒）
  static const int _gifDurationMs = 3000;

  final FlutterTts _tts = FlutterTts();
  int _scene = 0;
  double _sceneOpacity = 0.0;
  bool _showStartBtn = false;
  bool _done = false;
  bool _ttsComplete = false;
  bool _minTimeReached = false;
  Timer? _minTimer;

  // Scene 0：GIF 播完一次後切靜止圖
  bool _gifDone = false;
  Timer? _gifTimer;

  late final AnimationController _ctrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _talkCtrl;

  late final Animation<double> _mascotEntrance;
  late final Animation<double> _zoomAnim;
  late final Animation<double> _fadeA;
  late final Animation<double> _fadeB;
  late final Animation<double> _fadeC;
  late final Animation<double> _pulse;

  // Scene 3 六項功能逐條淡入
  final List<Animation<double>> _featureFades = [];

  static const _scripts = [
    '嗨！我是你的防災小助理！很高興認識你！',
    '主畫面有六大功能，包括緊急求救、防空洞地圖、健康回報、防災知識、聊天室，還有物資捐贈，都是關鍵時刻最需要的工具！',
    '不管你在哪個畫面，我都會在右下角等你喔！',
    '有任何問題，點一下我，我就能告訴你每個功能怎麼使用！在任何頁面，我都在右下角等著你。準備好了嗎？讓我們開始吧！',
  ];

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initTts().then((_) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _goScene(0));
      }
    });
  }

  Future<void> _initTts() async {
    _tts.setErrorHandler((msg) => debugPrint('TTS error: $msg'));
    try {
      final dynamic raw = await _tts.getLanguages;
      final List<String> langs =
          (raw as List?)?.map((e) => e.toString()).toList() ?? [];
      String pick = 'zh-TW';
      if (langs.contains('zh-TW')) {
        pick = 'zh-TW';
      } else if (langs.contains('zh-CN')) {
        pick = 'zh-CN';
      } else {
        pick = langs.firstWhere(
          (l) => l.toLowerCase().startsWith('zh'),
          orElse: () => 'zh-TW',
        );
      }
      await _tts.setLanguage(pick);
    } catch (_) {
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

    _talkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    // Scene 0：小助理從螢幕底部彈入
    _mascotEntrance = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.65, curve: Curves.elasticOut),
    );

    // Scene 2：放大至右下角
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

    _pulse = Tween<double>(begin: 0.88, end: 1.12).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Scene 3 六功能依序淡入
    for (int i = 0; i < 6; i++) {
      final s = (0.48 + i * 0.07).clamp(0.0, 0.88);
      _featureFades.add(CurvedAnimation(
        parent: _ctrl,
        curve:
            Interval(s, (s + 0.22).clamp(0.0, 1.0), curve: Curves.easeOut),
      ));
    }
  }

  Future<void> _goScene(int s) async {
    if (!mounted || _done) return;
    _minTimer?.cancel();
    _gifTimer?.cancel();
    _ttsComplete = false;
    _minTimeReached = false;

    setState(() => _sceneOpacity = 0.0);
    await Future.delayed(const Duration(milliseconds: 220));
    if (!mounted || _done) return;

    setState(() {
      _scene = s;
      _showStartBtn = false;
    });
    _ctrl..reset()..forward();
    setState(() => _sceneOpacity = 1.0);

    // Scene 0：啟動 GIF 計時，時間到切靜止圖
    if (s == 0) {
      setState(() => _gifDone = false);
      _gifTimer = Timer(Duration(milliseconds: _gifDurationMs), () {
        if (mounted && !_done && _scene == 0) {
          setState(() => _gifDone = true);
        }
      });
    }

    // Scene 2 & 3：開始嘴巴開合動畫
    if (s == 2 || s == 3) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && !_done && _scene == s) _talkCtrl.repeat();
      });
    } else {
      _talkCtrl.stop();
      _talkCtrl.reset();
    }

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted || _done) return;
    await _tts.speak(_scripts[s]);

    final minMs = (_scripts[s].length * 200 + 4000).clamp(8000, 18000);
    _minTimer = Timer(Duration(milliseconds: minMs), () {
      if (!_done && mounted) {
        _minTimeReached = true;
        if (_ttsComplete) _tryAutoAdvance();
      }
    });
  }

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
    _gifTimer?.cancel();
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
    _gifTimer?.cancel();
    _ctrl.dispose();
    _pulseCtrl.dispose();
    _talkCtrl.dispose();
    super.dispose();
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Scene content
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: _sceneOpacity,
              child: _buildScene(size),
            ),

            // 跳過按鈕
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

            // 底部 ← 點點 →
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
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
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          4,
                          (i) => AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: _scene == i ? 24 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _scene == i
                                  ? _brown
                                  : _brown.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
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

            // 開始使用按鈕
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

  // ── Scene 0：小助理 GIF 揮手（播一次停住）─────────────────────────────────

  Widget _buildScene0(Size size) {
    final mascotW = size.width;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // 上方文字
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

        // 小助理：從螢幕底部彈入，播放 GIF 一次後切靜止圖
        AnimatedBuilder(
          animation: _mascotEntrance,
          builder: (_, child) {
            final t = _mascotEntrance.value;
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
          // GIF 播完後切換到靜止圖；GIF 不存在時也 fallback 到靜止圖
          child: _gifDone
              ? Image.asset(
                  'assets/images/mascot_hi.png',
                  width: mascotW,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _mascotFallback(mascotW),
                )
              : Image.asset(
                  'assets/images/mascot_wave.gif',
                  width: mascotW,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Image.asset(
                    'assets/images/mascot_hi.png',
                    width: mascotW,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => _mascotFallback(mascotW),
                  ),
                ),
        ),
      ],
    );
  }

  // ── Scene 1：主頁樣式（手機框 + 小助理在右下角）────────────────────────────

  Widget _buildScene1(Size size) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 小助理說話泡泡
          FadeTransition(
            opacity: _fadeA,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _mascotImg('assets/images/mascot_talking.png', 60),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 11),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(14),
                        topRight: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.07),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Text(
                      '主畫面有六大功能，\n都是關鍵時刻最需要的工具！',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 手機框：展示完整主頁，小助理在右下角
          FadeTransition(
            opacity: _fadeB,
            child: Center(
              child: _PhoneMockup(
                pulse: _pulse,
                size: size,
                talkAnim: _talkCtrl, // 停止中 → 顯示靜止小助理
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Scene 2：同樣手機框，鏡頭慢慢放大至右下角小助理 ────────────────────────

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

        // 手機框漸漸放大，焦點固定在右下角小助理
        AnimatedBuilder(
          animation: _zoomAnim,
          builder: (_, child) {
            final z = _zoomAnim.value;
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
              talkAnim: _talkCtrl, // 小助理開始說話
            ),
          ),
        ),
      ],
    );
  }

  // ── Scene 3：模擬點擊小助理，出現功能說明文字泡泡 ───────────────────────────

  Widget _buildScene3(Size size) {
    // 每個功能的說明文字（emoji、名稱、一句話介紹）
    const features = [
      ('🆘', 'SOS 緊急求救', '一鍵傳送位置，立刻通知緊急聯絡人'),
      ('📚', '防災知識', '學習地震、火災、颱風等應急技能'),
      ('🗺️', '防空洞地圖', '找到離你最近的避難所'),
      ('❤️', '健康回報', '告知家人你目前是否平安'),
      ('💬', '聊天室', '和附近鄰居即時互助聯絡'),
      ('🎁', '物資捐贈', '分享或領取緊急生活物資'),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 120),
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
          const SizedBox(height: 24),

          FadeTransition(
            opacity: _fadeB,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 說明泡泡（左側）
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(18),
                        topRight: Radius.circular(18),
                        bottomRight: Radius.circular(18),
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
                          '嗨！我在這裡 ✨',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: _textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '在每個頁面點我，我都能告訴你怎麼用！',
                          style: TextStyle(
                            fontSize: 11,
                            color: _textSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // 六功能依序淡入
                        ...List.generate(features.length, (i) {
                          final opt = features[i];
                          return FadeTransition(
                            opacity: _featureFades[i],
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(opt.$1,
                                      style: const TextStyle(fontSize: 15)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          opt.$2,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: _textPrimary,
                                          ),
                                        ),
                                        Text(
                                          opt.$3,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: _textSecondary,
                                            height: 1.3,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // 右側小助理（脈衝跳動，吸引點擊）
                ScaleTransition(
                  scale: _pulse,
                  child: _mascotImg('assets/images/mascot_hi.png', 88),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 提示文字
          FadeTransition(
            opacity: _fadeC,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: _brown.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.touch_app_rounded,
                      size: 15, color: _brown.withValues(alpha: 0.7)),
                  const SizedBox(width: 6),
                  Text(
                    '任何頁面都可以點我喔！',
                    style: TextStyle(
                      fontSize: 12,
                      color: _brown.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Widget _mascotImg(String path, double size) {
    return Image.asset(
      path,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => _mascotFallback(size),
    );
  }

  Widget _mascotFallback(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _brown.withValues(alpha: 0.08),
      ),
      child: Icon(Icons.support_agent_rounded,
          size: size * 0.55, color: _brown),
    );
  }
}

// ── Phone mockup（Scene 1 & 2 共用）─────────────────────────────────────────

class _PhoneMockup extends StatelessWidget {
  final Animation<double> pulse;
  final Size size;
  final AnimationController talkAnim;

  const _PhoneMockup({
    required this.pulse,
    required this.size,
    required this.talkAnim,
  });

  Widget _miniTile(IconData icon, String label, Color color) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(5)),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        color.withValues(alpha: 0.18),
                        color.withValues(alpha: 0.07),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: Center(child: Icon(icon, color: color, size: 9)),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Center(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 4.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3D2C1E),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
              // 主頁畫面
              Container(
                color: const Color(0xFFF7F3EC),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // AppBar
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
                    // 歡迎語
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(10, 2, 10, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '平安是福，互CARES',
                            style: TextStyle(
                              fontSize: 7.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF3D2C1E),
                            ),
                          ),
                          Text(
                            '讓每一個求助不被忽略',
                            style: TextStyle(
                              fontSize: 5,
                              color: const Color(0xFF8C7B6E).withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 功能卡片
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(5, 2, 5, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // SOS 大卡
                            Container(
                              height: 20,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFD96048),
                                    Color(0xFFBF4530)
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6),
                              child: Row(
                                children: const [
                                  Icon(Icons.sos_rounded,
                                      color: Colors.white, size: 8),
                                  SizedBox(width: 3),
                                  Text(
                                    'SOS 緊急求救',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 5.5,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            // 2×2 功能卡
                            Expanded(
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        _miniTile(
                                            Icons.auto_stories_rounded,
                                            '防災知識',
                                            const Color(0xFF7AA67A)),
                                        const SizedBox(width: 4),
                                        _miniTile(
                                            Icons.location_on_rounded,
                                            '防空洞',
                                            const Color(0xFF6B9EAD)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        _miniTile(
                                            Icons.favorite_rounded,
                                            '健康回報',
                                            const Color(0xFFBF7A5A)),
                                        const SizedBox(width: 4),
                                        _miniTile(
                                            Icons.chat_bubble_rounded,
                                            '聊天室',
                                            const Color(0xFF9B88B3)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            // 物資捐贈（寬版）
                            Container(
                              height: 18,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Row(
                                children: const [
                                  Icon(Icons.volunteer_activism_rounded,
                                      color: Color(0xFF7AA67A), size: 8),
                                  SizedBox(width: 4),
                                  Text(
                                    '物資捐贈',
                                    style: TextStyle(
                                      fontSize: 5.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF3D2C1E),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 右下角小助理（脈衝光暈 + 嘴巴開合）
              Positioned(
                right: -4,
                bottom: 8,
                child: ScaleTransition(
                  scale: pulse,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFE8C99A)
                              .withValues(alpha: 0.5),
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

              // 「我在這裡！」標籤
              Positioned(
                right: 38,
                bottom: 24,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 4),
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
