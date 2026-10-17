import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/sos_service.dart';
import '../widgets/fill_or_scroll.dart';

/// 一次送出 SOS 的結果。
enum _SendOutcome {
  /// 伺服器已確認收到。
  sent,

  /// 離線，已進本機佇列，恢復連線才會送出。
  queued,

  /// 沒送出（沒有個人資料、寫入被拒）。
  failed,
}

class SOSScreen extends StatefulWidget {
  const SOSScreen({super.key});

  @override
  State<SOSScreen> createState() => _SOSScreenState();
}

class _SOSScreenState extends State<SOSScreen> with TickerProviderStateMixin {
  final SOSService _sosService = SOSService();

  /// 要持續按住多久才算送出。一碰就送很容易在口袋裡或慌亂中誤觸。
  static const _holdDuration = Duration(seconds: 3);

  /// 待機時的心跳式跳動，提示這顆按鈕可以按。
  late final AnimationController _pulseController;

  /// 按住的進度（0 → 1），驅動外圈進度環與按鈕由小變大。
  late final AnimationController _holdController;

  /// 按下瞬間的「往下壓」：按鈕縮小、下沉、陰影變淺。
  late final AnimationController _pressController;

  final AudioPlayer _chargePlayer = AudioPlayer();
  final AudioPlayer _alertPlayer = AudioPlayer();

  /// 蓄力音效先載好：play() 要先載入音檔才開始播，快速點一下就放開時，
  /// stop() 會在還沒開始播之前就呼叫，等載入完音效還是整段播完。
  late final Future<void> _chargeReady;

  /// 上一次觸發震動時已經過的整秒數，用來每滿一秒震一下。
  int _lastHapticSecond = 0;

  /// 正在長按的那根手指。長按期間不理其他手指：慌張時第二根手指或手掌碰到
  /// 按鈕，不該讓計時重來，也不該因為那根手指放開就取消。
  int? _activePointer;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _sosRed = Color(0xFFC4553A);

  AppUser? _currentUser;
  Position? _position;
  bool _sosSent = false;
  bool _isSending = false;

  /// 送出時連不上 Firestore：資料在本機佇列裡，還沒真的到後端。
  bool _queuedOffline = false;
  bool _isLoadingLocation = true;
  DateTime? _sentAt;

  /// 送出的那一刻有沒有位置。橫幅要看這個，不能看即時的 [_position]：
  /// 定位晚到時 [_position] 會有值，但已經送出的 SOS 裡其實沒有座標。
  bool _sentWithoutLocation = false;

  /// 已送出 SOS 的文件 ID，定位晚到時用來補寫座標。
  String? _sosDocId;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
    _holdController = AnimationController(
      vsync: this,
      duration: _holdDuration,
      reverseDuration: const Duration(milliseconds: 300),
    )
      ..addListener(_onHoldTick)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _onHoldComplete();
      });
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _chargeReady = _chargePlayer
        // 預設的 ReleaseMode.release 在 stop() 後會釋放音檔，下次按就得重新載入。
        .setReleaseMode(ReleaseMode.stop)
        .then(
          (_) => _chargePlayer.setSource(AssetSource('sounds/sos_charge.wav')),
        )
        .catchError((Object e) => debugPrint('load charge sound failed: $e'));
    _loadUser();
    _fetchLocation();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _holdController.dispose();
    _pressController.dispose();
    _chargePlayer.dispose();
    _alertPlayer.dispose();
    super.dispose();
  }

  bool get _canHold => !_sosSent && !_isSending;

  bool get _isHolding => _holdController.status == AnimationStatus.forward;

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointer != null) return;
    _activePointer = event.pointer;
    _onHoldStart();
  }

  /// 放開與取消都走這裡，只認當初按下的那根手指。
  void _onPointerEnd(PointerEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _onHoldEnd();
  }

  void _onHoldStart() {
    if (!_canHold) return;
    _lastHapticSecond = 0;
    HapticFeedback.mediumImpact();
    _pressController.forward();
    _holdController.forward(from: 0);
    unawaited(_startChargeSound());
  }

  /// 音檔載好、真的開始播之後再確認一次手指還按著，否則馬上停掉。
  Future<void> _startChargeSound() async {
    try {
      await _chargeReady;
      if (!_isHolding) return;
      await _chargePlayer.resume();
      if (!_isHolding) await _chargePlayer.stop();
    } catch (e) {
      debugPrint('play charge sound failed: $e');
    }
  }

  void _onHoldEnd() {
    _pressController.reverse();
    if (!_isHolding) return;
    _holdController.reverse();
    _chargePlayer.stop();
    _showMessage('請持續按住 3 秒才會送出求救', _sosRed);
  }

  /// 每滿一秒震一下，讓人不看螢幕也知道還要按多久。
  void _onHoldTick() {
    if (_holdController.status != AnimationStatus.forward) return;
    final second = (_holdController.value * _holdDuration.inSeconds).floor();
    if (second > _lastHapticSecond) {
      _lastHapticSecond = second;
      HapticFeedback.mediumImpact();
    }
  }

  void _onHoldComplete() {
    // 按滿 3 秒時只震動，表示「收到、正在送」；還不知道有沒有送成功。
    HapticFeedback.heavyImpact();
    _chargePlayer.stop();
    _pressController.reverse();
    _holdController.value = 0;
    unawaited(_sendAndAnnounce());
  }

  /// 送出 SOS，確定伺服器收到了才播「成功」音效。
  ///
  /// 求救的人很可能沒在看螢幕，聽到「成功」就會以為救援要來了。所以送出失敗
  /// 不播；離線暫存也還沒到後端，先不播，等之後真的送到再播
  /// （[_followQueuedSend]）。
  Future<void> _sendAndAnnounce() async {
    final outcome = await _sendSOS();
    if (outcome == _SendOutcome.sent) _playSuccessSound();
  }

  void _playSuccessSound() {
    if (!mounted) return;
    _alertPlayer
        .play(AssetSource('sounds/sos_success.wav'))
        .catchError((Object e) => debugPrint('play success sound failed: $e'));
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_user');
    if (raw != null && mounted) {
      setState(() => _currentUser = AppUser.fromJson(jsonDecode(raw)));
    }
  }

  Future<void> _fetchLocation() async {
    setState(() => _isLoadingLocation = true);
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _isLoadingLocation = false);
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        setState(() => _isLoadingLocation = false);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (mounted) setState(() => _position = pos);
      _attachLateLocation(pos);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<_SendOutcome> _sendSOS() async {
    if (_isSending) return _SendOutcome.failed;

    // 先前這裡是 `if (_currentUser == null) return;`：本機沒有個人資料時，
    // 按下 SOS 完全沒有反應 —— 不送出、不報錯、也沒有任何提示。求救的人
    // 會以為已經送出去了。
    final user = _currentUser;
    if (user == null) {
      _showMessage('找不到你的個人資料，無法送出求救。請重新登入後再試。', _sosRed);
      return _SendOutcome.failed;
    }

    setState(() => _isSending = true);
    try {
      // 拿不到定位就送 null。座標是救援端唯一能用來找人的欄位，寧可明確地
      // 「沒有位置」，也不要送一個看起來合理、實際上錯得離譜的 0, 0。
      final position = _position;
      final submission = _sosService.sendSOS(
        userId: user.id,
        userName: user.name,
        phone: user.phone,
        lat: position?.latitude,
        lng: position?.longitude,
        bloodType: user.bloodType,
        medicalInfo: user.medicalInfo,
      );
      // 文件 ID 一拿到就記下來：等待伺服器確認的這段時間裡定位也可能回來。
      _sosDocId = submission.id;
      _sentWithoutLocation = position == null;
      final send = submission.write;

      // Firestore 的寫入要等伺服器確認才完成，離線時永遠不會完成（資料已進
      // 本機佇列，恢復連線會自動送出）。求救的人不能對著一顆轉不停的按鈕等，
      // 所以逾時就照實說明狀況。
      var queuedOffline = false;
      try {
        await send.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        queuedOffline = true;
        unawaited(_followQueuedSend(send));
      }

      final outcome = queuedOffline ? _SendOutcome.queued : _SendOutcome.sent;
      if (!mounted) return outcome;
      setState(() {
        _sosSent = true;
        _sentAt = DateTime.now();
        _queuedOffline = queuedOffline;
      });

      if (queuedOffline) {
        _showMessage('目前離線，求救已暫存，恢復連線後會自動送出。', const Color(0xFFBF7A5A));
      } else if (_sentWithoutLocation) {
        _showMessage('求救已送出，但沒有附上位置。請盡量用其他方式告知所在地。', const Color(0xFFBF7A5A));
      }

      // 等待確認的期間定位已經回來的話，現在補寫。
      final arrived = _position;
      if (arrived != null) _attachLateLocation(arrived);
      return outcome;
    } catch (e) {
      debugPrint('sendSOS failed: $e');
      _sosDocId = null;
      if (mounted) _showMessage('發送失敗，請再試一次。', _sosRed);
      return _SendOutcome.failed;
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// 離線排隊的 SOS 之後送到或失敗，畫面都要跟著更新。
  ///
  /// 送到了：橫幅不能一直停在「已暫存」。失敗了（例如權限被擋）：只記 log 的話，
  /// 求救的人會一直以為恢復連線就會送出，所以要說出來並讓按鈕可以再按。
  Future<void> _followQueuedSend(Future<void> send) async {
    try {
      await send;
      if (!mounted) return;
      setState(() => _queuedOffline = false);
      _playSuccessSound();
    } catch (e) {
      debugPrint('queued SOS failed: $e');
      _sosDocId = null;
      if (!mounted) return;
      setState(() {
        _sosSent = false;
        _queuedOffline = false;
        _sentAt = null;
      });
      _showMessage('暫存的求救沒有送出，請再按一次 SOS。', _sosRed);
    }
  }

  /// 送出時還沒有位置、之後定位才回來：把座標補寫進同一筆 SOS。
  ///
  /// 補寫確認之後橫幅才拿掉「沒有附上位置」；失敗就維持原樣，不假裝已補上。
  void _attachLateLocation(Position pos) {
    final id = _sosDocId;
    if (id == null || !_sentWithoutLocation) return;
    _sosDocId = null; // 只補一次
    _sosService
        .attachLocation(id, lat: pos.latitude, lng: pos.longitude)
        .then((_) {
      if (mounted) setState(() => _sentWithoutLocation = false);
    }, onError: (Object e) {
      debugPrint('attach late SOS location failed: $e');
    });
  }

  void _showMessage(String message, Color color) {
    if (!mounted) return;
    // SnackBar 是排隊一個一個顯示的。慌張連點時每次都會跳「請持續按住」，
    // 不先收掉舊的，送出結果要等前面那串播完才看得到。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: color,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 5),
        ),
      );
  }

  /// 上方橫幅的顏色。送出但「有但書」（離線暫存、沒有位置）時不給全綠 ——
  /// 綠色會讓人以為救援端已經完整收到，包含位置。
  Color get _statusColor {
    if (!_sosSent) return _sosRed;
    if (_queuedOffline || _sentWithoutLocation) return const Color(0xFFBF7A5A);
    return const Color(0xFF7AA67A);
  }

  /// 上方橫幅的文字。送出之後要照實說明狀況：離線暫存、以及有沒有附上位置，
  /// 都直接影響求救的人接下來該怎麼做。
  String get _statusMessage {
    if (!_sosSent) return '長按下方按鈕 3 秒發出求救訊號';
    if (_queuedOffline) return '目前離線，求救已暫存，恢復連線後會自動送出。';
    if (_sentWithoutLocation) return 'SOS 已發送，但沒有附上位置，請設法告知所在地。';
    return 'SOS 已發送，請保持冷靜等待救援。';
  }

  String get _locationText {
    if (_isLoadingLocation) return '取得位置中…';
    if (_position == null) return '無法取得位置';
    return '${_position!.latitude.toStringAsFixed(4)}, ${_position!.longitude.toStringAsFixed(4)}';
  }

  String get _sentTimeText {
    if (!_sosSent || _sentAt == null) return '尚未發送';
    return '${_sentAt!.hour.toString().padLeft(2, '0')}:${_sentAt!.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('SOS 緊急求救'),
        iconTheme: const IconThemeData(color: _textPrimary),
      ),
      body: SafeArea(
        // 小螢幕、大字體時按鈕與資訊卡放不下，改成可以捲動；放得下時照舊用 Spacer 撐開（#79）。
        child: FillOrScroll(
          padding: const EdgeInsets.all(20),
          fillWithFlex: true,
          child: Column(
            children: [
              // 狀態提示
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: _statusColor.withValues(alpha: 0.45)),
                ),
                child: Row(
                  children: [
                    Icon(
                      !_sosSent
                          ? Icons.info_outline_rounded
                          : (_queuedOffline || _sentWithoutLocation
                              ? Icons.warning_amber_rounded
                              : Icons.check_circle_rounded),
                      color: _statusColor,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _statusMessage,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _statusColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // SOS 大圓按鈕：長按 3 秒才送出，避免誤觸
              Semantics(
                button: true,
                label: _sosSent ? 'SOS 已發送' : 'SOS 緊急求救，長按 3 秒送出',
                // 讀螢幕軟體沒有「按住 3 秒」的手勢，改用長按動作直接送出。
                onLongPress: _canHold ? _sendAndAnnounce : null,
                excludeSemantics: true,
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerUp: _onPointerEnd,
                  onPointerCancel: _onPointerEnd,
                  child: SizedBox(
                    width: 280,
                    height: 280,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([
                        _pulseController,
                        _holdController,
                        _pressController,
                      ]),
                      builder: (context, _) => _buildSosButton(),
                    ),
                  ),
                ),
              ),

              const Spacer(),

              // 位置 & 用戶資訊卡
              Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF3D2C1E,
                          ).withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _infoRow(
                          Icons.person_rounded,
                          '姓名',
                          _currentUser?.name ?? '載入中…',
                        ),
                        const Divider(height: 20, color: Color(0xFFE8E0D5)),
                        _infoRow(
                          Icons.location_on_rounded,
                          '目前位置',
                          _locationText,
                        ),
                        const Divider(height: 20, color: Color(0xFFE8E0D5)),
                        _infoRow(
                          Icons.phone_rounded,
                          '緊急電話',
                          '119 消防 ／ 110 警察',
                        ),
                        const Divider(height: 20, color: Color(0xFFE8E0D5)),
                        _infoRow(
                          Icons.access_time_rounded,
                          '發送時間',
                          _sentTimeText,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_sosSent)
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => setState(() {
                          _sosSent = false;
                          _sentAt = null;
                        }),
                        child: Text(
                          '重置',
                          style: TextStyle(color: _textSecondary),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 以 [center] 為中心的一個凸起（0 → 1 → 0），組成心跳的兩下。
  static double _bump(double t, double center) {
    final d = (t - center) / 0.07;
    return math.exp(-d * d);
  }

  Widget _buildSosButton() {
    final hold = _holdController.value;
    final holdEased = Curves.easeOut.transform(hold);
    final press = _pressController.value;
    final holding = _holdController.status == AnimationStatus.forward;
    final idle = _canHold && hold == 0 && press == 0;

    // 待機：心跳式的「咚、咚」兩下
    final t = _pulseController.value;
    final beat = idle ? math.max(_bump(t, 0.15), 0.6 * _bump(t, 0.4)) : 0.0;

    // 按下先往下壓縮小，按住期間再一路由小變大
    final scale = (1 + 0.06 * beat) * (1 - 0.12 * press) * (1 + 0.3 * holdEased);
    final sink = 6 * press;

    final baseColor = _sosSent ? const Color(0xFF9E9690) : _sosRed;
    final color = Color.lerp(baseColor, const Color(0xFFA2361F), holdEased)!;
    final remaining =
        (_holdDuration.inSeconds - (hold * _holdDuration.inSeconds).floor())
            .clamp(1, _holdDuration.inSeconds);

    return Stack(
      alignment: Alignment.center,
      children: [
        // 待機時向外擴散的波紋
        if (idle)
          for (final offset in const [0.0, 0.5])
            Builder(builder: (context) {
              final p = (t + offset) % 1.0;
              return Container(
                width: 200 + 80 * p,
                height: 200 + 80 * p,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _sosRed.withValues(alpha: 0.35 * (1 - p)),
                    width: 2,
                  ),
                ),
              );
            }),

        // 按住時的進度環
        if (hold > 0)
          SizedBox(
            width: 266,
            height: 266,
            child: CircularProgressIndicator(
              value: hold,
              strokeWidth: 6,
              strokeCap: StrokeCap.round,
              color: _sosRed,
              backgroundColor: _sosRed.withValues(alpha: 0.15),
            ),
          ),

        Transform.translate(
          offset: Offset(0, sink),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.35 + 0.2 * holdEased),
                    blurRadius: 36 - 24 * press + 20 * holdEased,
                    spreadRadius: 6 - 4 * press + 8 * holdEased,
                    offset: Offset(0, 8 - 6 * press),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1.5,
                      ),
                    ),
                  ),
                  if (_isSending)
                    const CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 3,
                    )
                  else if (holding)
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '$remaining',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 56,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '持續按住',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _sosSent ? Icons.check_rounded : Icons.sos_rounded,
                          color: Colors.white,
                          size: 52,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _sosSent ? '已發送' : '長按 3 秒',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _textSecondary),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: _textSecondary),
        ),
        const SizedBox(width: 12),
        // 值太長（大字體、窄螢幕）時換行，不超出卡片（#79）。
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
