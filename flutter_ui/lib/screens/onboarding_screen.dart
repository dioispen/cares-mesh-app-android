import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:gif/gif.dart';
import 'home_screen.dart';
import '../services/mascot_service.dart';

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
  final AudioPlayer _audioPlayer = AudioPlayer();
  late GifController _introGifCtrl;
  late GifController _waveGifCtrl;
  int _scene = 0;
  double _sceneOpacity = 0.0;
  bool _showStartBtn = false;
  bool _done = false;
  bool _ttsComplete = false;
  bool _minTimeReached = false;
  Timer? _minTimer;
  bool _inFeatureTour = false;
  int _highlightedFeature = -1;
  Completer<void>? _currentAudioCompleter;
  int _scene2Phase = 0;

  // Scene 0：GIF 播完一次後切靜止圖

  late final AnimationController _ctrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _talkCtrl;

  late final Animation<double> _fadeA;
  late final Animation<double> _fadeB;

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

    _audioPlayer.onPlayerComplete.listen((_) {
      if (_currentAudioCompleter != null && !_currentAudioCompleter!.isCompleted) {
        _currentAudioCompleter!.complete();
      }
      if (!_done && mounted && !_inFeatureTour) {
        _ttsComplete = true;
        if (_minTimeReached) _tryAutoAdvance();
      }
    });
  }

  void _initAnimations() {
    _introGifCtrl = GifController(vsync: this);
    _waveGifCtrl = GifController(vsync: this);

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


    _fadeA = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.3, 0.7, curve: Curves.easeOut),
    );
    _fadeB = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.5, 0.9, curve: Curves.easeOut),
    );
  }

  Future<void> _goScene(int s) async {
    if (!mounted || _done) return;
    _minTimer?.cancel();
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

    _talkCtrl.stop();
    _talkCtrl.reset();

    final preDelay = s == 0 ? 1800 : 300;
    await Future.delayed(Duration(milliseconds: preDelay));
    if (!mounted || _done) return;

    if (s == 0) {
      _introGifCtrl.reset();
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (!mounted || _done || _scene != 0) return;
        _introGifCtrl.repeat();
      });
      await _audioPlayer.play(AssetSource('mp3/audio_1.mp3'));
      _minTimer = Timer(const Duration(milliseconds: 6000), () {
        if (!_done && mounted) {
          _minTimeReached = true;
          if (_ttsComplete) _tryAutoAdvance();
        }
      });
    } else if (s == 1) {
      _startFeatureTour();
    } else {
      if (mounted) setState(() => _scene2Phase = 0);
      _startScene2Sequence();
      await _audioPlayer.play(AssetSource('mp3/audio_3.mp3'));
      _minTimer = Timer(const Duration(milliseconds: 12000), () {
        if (!_done && mounted) {
          _minTimeReached = true;
          if (_ttsComplete) _tryAutoAdvance();
        }
      });
    }
  }

  void _startScene2Sequence() {
    // Phase 1：縮放 + 點擊漣漪
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted || _done || _scene != 2) return;
      setState(() => _scene2Phase = 1);

      // Phase 2：泡泡框（問候 + 選項）出現
      Future.delayed(const Duration(milliseconds: 2800), () {
        if (!mounted || _done || _scene != 2) return;
        setState(() => _scene2Phase = 2);

        // Phase 3：選項高亮（停留 4 秒）
        Future.delayed(const Duration(milliseconds: 4000), () {
          if (!mounted || _done || _scene != 2) return;
          setState(() => _scene2Phase = 3);

          // Phase 4：切換成回答（停留 4 秒）
          Future.delayed(const Duration(milliseconds: 4000), () {
            if (!mounted || _done || _scene != 2) return;
            setState(() => _scene2Phase = 4);
          });
        });
      });
    });
  }

  Future<void> _startFeatureTour() async {
    _inFeatureTour = true;

    // 先播開頭
    if (mounted && !_done) {
      _currentAudioCompleter = Completer<void>();
      await _audioPlayer.play(AssetSource('mp3/audio_2_0.mp3'));
      await _currentAudioCompleter!.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
      _currentAudioCompleter = null;
      if (mounted && !_done) await Future.delayed(const Duration(milliseconds: 300));
    }

    const audioFiles = [
      'mp3/audio_2_1.mp3',
      'mp3/audio_2_2.mp3',
      'mp3/audio_2_3.mp3',
      'mp3/audio_2_4.mp3',
      'mp3/audio_2_5.mp3',
      'mp3/audio_2_6.mp3',
    ];

    for (int i = 0; i < audioFiles.length; i++) {
      if (!mounted || _done || !_inFeatureTour || _scene != 1) break;
      if (mounted) setState(() => _highlightedFeature = i);
      _currentAudioCompleter = Completer<void>();
      await _audioPlayer.play(AssetSource(audioFiles[i]));
      await _currentAudioCompleter!.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {},
      );
      _currentAudioCompleter = null;
      if (!mounted || _done || !_inFeatureTour || _scene != 1) break;
      await Future.delayed(const Duration(milliseconds: 400));
    }

    _inFeatureTour = false;
    _currentAudioCompleter = null;
    if (mounted) setState(() => _highlightedFeature = -1);
    if (!_done && mounted && _scene == 1) {
      _ttsComplete = true;
      _minTimeReached = true;
      _tryAutoAdvance();
    }
  }

  void _tryAutoAdvance() {
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (!_done && mounted && _ttsComplete && _minTimeReached) {
        if (_scene < 2) {
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
    _audioPlayer.stop();
    _minTimer?.cancel();
    _inFeatureTour = false;
    if (_currentAudioCompleter != null && !_currentAudioCompleter!.isCompleted) {
      _currentAudioCompleter!.complete();
    }
    _currentAudioCompleter = null;
    if (mounted) setState(() => _highlightedFeature = -1);
    if (_scene < 2) {
      _goScene(_scene + 1);
    } else {
      setState(() => _showStartBtn = true);
    }
  }

  void _manualBack() {
    if (_done || _scene <= 0) return;
    _tts.stop();
    _audioPlayer.stop();
    _minTimer?.cancel();
    _inFeatureTour = false;
    if (_currentAudioCompleter != null && !_currentAudioCompleter!.isCompleted) {
      _currentAudioCompleter!.complete();
    }
    _currentAudioCompleter = null;
    if (mounted) setState(() => _highlightedFeature = -1);
    _goScene(_scene - 1);
  }

  void _skip() {
    _done = true;
    _tts.stop();
    _audioPlayer.stop();
    _minTimer?.cancel();
    _inFeatureTour = false;
    if (_currentAudioCompleter != null && !_currentAudioCompleter!.isCompleted) {
      _currentAudioCompleter!.complete();
    }
    _currentAudioCompleter = null;
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
    _audioPlayer.dispose();
    _introGifCtrl.dispose();
    _waveGifCtrl.dispose();
    _minTimer?.cancel();
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
                          3,
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
        _ => _buildScene2(size),
      };

  // ── Scene 0：小助理 GIF 揮手（播一次停住）─────────────────────────────────

  Widget _buildScene0(Size size) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
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
        const SizedBox(height: 12),
        FadeTransition(
          opacity: _fadeA,
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
        const SizedBox(height: 24),
        Gif(
          image: const AssetImage('assets/images/mascot_intro.gif'),
          controller: _introGifCtrl,
          autostart: Autostart.no,
          width: size.width * 0.85,
          fit: BoxFit.contain,
        ),
      ],
    );
  }

  // ── Scene 1：首頁完整複製 + 右下角站立小助理 ──────────────────────────────────

  Widget _buildScene1(Size size) {
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          child: FadeTransition(
            opacity: _fadeA,
            child: _homeContent(highlight: _highlightedFeature),
          ),
        ),
        // 右下角站立小助理
        Positioned(
          right: -11,
          bottom: 72,
          child: FadeTransition(
            opacity: _fadeB,
            child: Image.asset(
              'assets/images/mascot_stand.png',
              width: 175,
              height: 175,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ],
    );
  }

  // ── Scene 2：首頁 + 小助理 → 放大右下角 → 揮手 GIF → 模擬點擊 → 泡泡框 ─────────

  Widget _buildScene2(Size size) {
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // 首頁內容 + 小助理，整體往右下角放大
        Positioned.fill(
          child: AnimatedScale(
            scale: _scene2Phase >= 1 ? 1.35 : 1.0,
            duration: const Duration(milliseconds: 900),
            alignment: Alignment.bottomRight,
            curve: Curves.easeInOut,
            child: Stack(
              children: [
                Positioned.fill(
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
                    child: _homeContent(),
                  ),
                ),
                // 小助理：phase 0-1 站立，phase 2-3 hi，phase 4+ talking
                Positioned(
                  right: -11,
                  bottom: 72,
                  child: Image.asset(
                    _scene2Phase >= 4
                        ? 'assets/images/mascot_talking.png'
                        : _scene2Phase >= 2
                            ? 'assets/images/mascot_hi.png'
                            : 'assets/images/mascot_stand.png',
                    width: 175,
                    height: 175,
                    fit: BoxFit.contain,
                  ),
                ),
              ],
            ),
          ),
        ),

        // 點擊漣漪動畫（phase 1）
        if (_scene2Phase == 1)
          Positioned(
            right: 48,
            bottom: 165,
            child: _clickRipple(),
          ),

        // 泡泡框（phase 2+）
        Positioned(
          right: 62,
          bottom: 330,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: _scene2Phase >= 2 ? 1.0 : 0.0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              offset: _scene2Phase >= 2 ? Offset.zero : const Offset(0.15, 0),
              child: _mockSpeechBubble(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _clickRipple() {
    return TweenAnimationBuilder<double>(
      key: const ValueKey('click-ripple'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 700),
      builder: (context, t, _) {
        return SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 24 + t * 50,
                height: 24 + t * 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _brown.withValues(alpha: (1 - t) * 0.55),
                    width: 2,
                  ),
                ),
              ),
              Icon(Icons.touch_app_rounded, size: 22, color: _brown.withValues(alpha: (1 - t * 0.5))),
            ],
          ),
        );
      },
    );
  }

  Widget _mockSpeechBubble() {
    final isResponse = _scene2Phase >= 4;
    final opt = homeOptions[0]; // 避難所在哪裡？

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 240,
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.13),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: isResponse ? _mockResponseContent(opt) : _mockGreetingContent(),
        ),
        Positioned(
          right: 16,
          bottom: -10,
          child: CustomPaint(
            painter: _BubbleTailPainter(),
            size: const Size(18, 11),
          ),
        ),
      ],
    );
  }

  Widget _mockGreetingContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: Text(
                '嗨！我是你的防災小助理 ✨',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF3D2C1E)),
              ),
            ),
            Icon(Icons.close_rounded, size: 16, color: _textSecondary),
          ],
        ),
        const SizedBox(height: 3),
        Text('有什麼需要幫助的嗎？', style: TextStyle(fontSize: 11, color: _textSecondary)),
        const SizedBox(height: 10),
        ...List.generate(homeOptions.length, (i) {
          final opt = homeOptions[i];
          final tapped = _scene2Phase >= 3 && i == 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: tapped ? const Color(0xFF5C3D2E).withValues(alpha: 0.12) : const Color(0xFFF7F3EC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: tapped ? const Color(0xFF5C3D2E).withValues(alpha: 0.5) : const Color(0xFFD4C5B0),
                  width: tapped ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Text(opt.icon, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      opt.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: const Color(0xFF3D2C1E),
                        fontWeight: tapped ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 14, color: _textSecondary),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _mockResponseContent(MascotOption opt) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.arrow_back_ios_new_rounded, size: 13, color: _textSecondary),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '${opt.icon} ${opt.label}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3D2C1E)),
              ),
            ),
            Icon(Icons.close_rounded, size: 16, color: _textSecondary),
          ],
        ),
        const SizedBox(height: 8),
        Container(height: 1, color: const Color(0xFF3D2C1E).withValues(alpha: 0.07)),
        const SizedBox(height: 8),
        Text(
          opt.response,
          style: const TextStyle(fontSize: 11, height: 1.6, color: Color(0xFF3D2C1E)),
        ),
      ],
    );
  }

  // ── 螢光黃高亮邊框（用 _pulseCtrl 閃爍）──────────────────────────────────────

  Widget _highlightGlow({required bool active, required Widget child, double radius = 18}) {
    if (!active) return child;
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (context, _) {
        final t = _pulseCtrl.value;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: const Color(0xFFFFE03A).withValues(alpha: 0.5 + t * 0.5),
              width: 2.0 + t * 2.0,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFE03A).withValues(alpha: 0.5 * t),
                blurRadius: 18,
                spreadRadius: 3,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }

  // ── 首頁內容（Scene 1 & 2 共用）─────────────────────────────────────────────

  Widget _homeContent({int highlight = -1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFC4553A).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Image.asset('assets/images/mascot_hi.png', width: 26, height: 26),
            ),
            const SizedBox(width: 8),
            const Text(
              '防災小助理：互CARES',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Text(
          '平安是福，互CARES',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _textPrimary, height: 1.2),
        ),
        const SizedBox(height: 4),
        Text(
          '從「Who cares？」到「互 CARES」，讓每一個求助不被忽略',
          style: TextStyle(fontSize: 12, color: _textSecondary),
        ),
        const SizedBox(height: 14),
        // SOS 大卡
        _highlightGlow(
          active: highlight == 0,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFD96048), Color(0xFFBF4530)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFC4553A).withValues(alpha: 0.35),
                  blurRadius: 14, offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SOS 緊急求救',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
                      SizedBox(height: 4),
                      Text('一鍵傳送 GPS 位置・即刻求援',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.sos_rounded, color: Colors.white, size: 28),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _onboardingFeatureCard('防災知識', '學習應急技能', Icons.auto_stories_rounded, const Color(0xFF7AA67A), highlighted: highlight == 1)),
            const SizedBox(width: 10),
            Expanded(child: _onboardingFeatureCard('防災避難所', '附近避難所', Icons.location_on_rounded, const Color(0xFF6B9EAD), highlighted: highlight == 2)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _onboardingFeatureCard('健康回報', '回報您的狀況', Icons.favorite_rounded, const Color(0xFFBF7A5A), highlighted: highlight == 3)),
            const SizedBox(width: 10),
            Expanded(child: _onboardingFeatureCard('互助通訊', '互助聯絡', Icons.chat_bubble_rounded, const Color(0xFF9B88B3), highlighted: highlight == 4)),
          ],
        ),
        const SizedBox(height: 10),
        _highlightGlow(
          active: highlight == 5,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFFEFDF9),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7AA67A).withValues(alpha: 0.15),
                  blurRadius: 10, offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 72, height: 60,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7AA67A).withValues(alpha: 0.12),
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                  ),
                  child: const Icon(Icons.volunteer_activism_rounded, color: Color(0xFF7AA67A), size: 28),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('物資捐贈', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _textPrimary)),
                      SizedBox(height: 2),
                      Text('認領需求物資', style: TextStyle(fontSize: 11, color: _textSecondary)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(Icons.chevron_right_rounded, color: _textSecondary.withValues(alpha: 0.5), size: 20),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _onboardingFeatureCard(String title, String sub, IconData icon, Color color, {bool highlighted = false}) {
    return _highlightGlow(
      active: highlighted,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFEFDF9),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.15), blurRadius: 10, offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 72,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Icon(icon, color: color, size: 30),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _textPrimary)),
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(fontSize: 11, color: _textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.07)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    final fill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width * 0.75, size.height)
      ..close();
    canvas.drawPath(path, shadow);
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(_BubbleTailPainter old) => false;
}
