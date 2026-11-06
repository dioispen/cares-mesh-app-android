import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/health_report_delivery.dart';
import '../models/user.dart';
import '../services/health_report_publisher.dart';
import '../services/mascot_service.dart';
import '../services/sos.dart' show SosState;
import '../widgets/fill_or_scroll.dart';

/// SOS 的求救要怎麼告訴使用者：兩條路各自的狀況，以及有沒有附上位置。
///
/// 斷網是災害現場的常態：mesh 已送出而雲端逾時，要說「附近裝置已收到」，不能說成失敗。
String sosDeliveryMessage(HealthReportDelivery delivery) {
  final outcome = switch ((delivery.broadcastFailure, delivery.uploadFailure)) {
    (null, null) when delivery.uploadQueued => '附近裝置已收到求救，雲端尚未上傳，恢復連線後會自動送出。',
    (final broadcast?, null) when delivery.uploadQueued => '目前離線，附近廣播也失敗（$broadcast）。求救已暫存，恢復連線後會自動送出。',
    (null, null) => delivery.withLocation ? 'SOS 已發送，請保持冷靜等待救援。' : 'SOS 已發送，但沒有附上位置，請設法告知所在地。',
    (final broadcast?, null) => '求救已上傳雲端，但附近廣播失敗（$broadcast）。',
    (null, final upload?) => '附近裝置已收到求救，但雲端上傳失敗（$upload）。',
    (final broadcast?, final upload?) => '發送失敗：附近廣播失敗（$broadcast），雲端上傳也失敗（$upload）。請再試一次。',
  };
  final caveatAlreadySaid = delivery.failed || delivery.complete;
  return delivery.withLocation || caveatAlreadySaid ? outcome : '$outcome沒有附上位置，請設法告知所在地。';
}

class SOSScreen extends StatefulWidget {
  const SOSScreen({super.key, this.publisher});

  /// 測試用；預設為 app 層級的 [HealthReportPublisher.instance]。
  final HealthReportPublisher? publisher;

  @override
  State<SOSScreen> createState() => _SOSScreenState();
}

/// SOS 是 Health Report 上的標記（ADR-0004）：長按 3 秒舉起 SOS，經 BLE mesh 廣播給附近裝置，
/// 同時寫進雲端自己的 `health_reports/{uid}`。舉起之後一直舉著，直到在這裡撤回、或到 Health 畫面
/// 回報安全（#82）。
class _SOSScreenState extends State<SOSScreen> with TickerProviderStateMixin {
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

  /// 沒按滿 3 秒就放開時，等一下才跳「請持續按住」：慌張時連續短點，只在最後一下之後跳一次。
  static const _holdHintDelay = Duration(milliseconds: 600);
  Timer? _holdHintTimer;

  /// 「請持續按住」的提示正在畫面上：再短點也不收掉重跳。
  bool _holdHintVisible = false;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _sosRed = Color(0xFFC4553A);
  static const _caveat = Color(0xFFBF7A5A);
  static const _green = Color(0xFF7AA67A);

  AppUser? _currentUser;
  Position? _position;
  bool _isLoadingLocation = true;

  HealthReportPublisher get _publisher => widget.publisher ?? HealthReportPublisher.instance;

  /// 目前的 SOS 狀態，隨 [_currentUser] 一起讀進來。
  SosState _sos = const SosState.lowered();
  bool _isSending = false;

  /// 這次進到畫面後最近一次舉起 SOS 的結果；從之前就舉著、這次還沒送過時為 null。
  HealthReportDelivery? _delivery;

  /// 上面那次送出用的位置，定位晚到時據此補送。沒有位置時為 null。
  Position? _sentPosition;

  @override
  void initState() {
    super.initState();
    // SOS 畫面不顯示小秘書，不論是從首頁大卡還是健康回報的「前往 SOS」進來。
    // 返回時，上一頁（首頁、健康回報）會在 didPopNext 把自己的小秘書叫回來。
    // postFrame 避免在 build 期間觸發 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mascotOptionsNotifier.value = const [];
    });
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
    _holdHintTimer?.cancel();
    _pulseController.dispose();
    _holdController.dispose();
    _pressController.dispose();
    _chargePlayer.dispose();
    _alertPlayer.dispose();
    super.dispose();
  }

  bool get _raised => _sos.raised;

  bool get _canHold => !_raised && !_isSending;

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
    // 又按下去了：上一下短點的提示先不跳，等這一下的結果。
    _holdHintTimer?.cancel();
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
    _holdHintTimer?.cancel();
    _holdHintTimer = Timer(_holdHintDelay, _showHoldHint);
  }

  void _showHoldHint() {
    if (!mounted || _holdHintVisible || _isHolding) return;
    final shown = _showMessage('請持續按住 3 秒才會送出求救', _sosRed);
    if (shown == null) return;
    _holdHintVisible = true;
    // 時間到、或被送出結果之類的訊息換掉，都會走到這裡。
    shown.closed.whenComplete(() => _holdHintVisible = false);
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
    unawaited(_raiseSos());
  }

  /// 確定有人收到了才播「成功」音效。
  ///
  /// 求救的人很可能沒在看螢幕，聽到「成功」就會以為救援要來了。所以 mesh 沒送出、雲端又只是
  /// 離線暫存時先不播，等之後真的上傳了再播（[_followQueuedUpload]）。
  void _playSuccessSound() {
    if (!mounted) return;
    _alertPlayer
        .play(AssetSource('sounds/sos_success.wav'))
        .catchError((Object e) => debugPrint('play success sound failed: $e'));
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_user');
    if (raw == null) return;
    final user = AppUser.fromJson(jsonDecode(raw));
    // 進到畫面時反映目前是否舉著 SOS、何時舉起的（#82）。
    final sos = await _publisher.sosState(user.id);
    if (!mounted) return;
    setState(() {
      _currentUser = user;
      _sos = sos;
    });
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
      unawaited(_sendLateLocation());
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  /// 長按完成時還沒有定位就用系統記得的最後位置，不等定位：求救要立刻送出（#81）。
  /// 兩者都沒有就不附位置，絕不送假座標。
  Future<Position?> _positionNow() async {
    final current = _position;
    if (current != null) return current;
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (e) {
      debugPrint('last known position unavailable: $e');
      return null;
    }
  }

  /// 舉起 SOS：不等定位、不等網路，立刻經 mesh 與雲端送出。
  Future<void> _raiseSos() async {
    if (_isSending) return;

    // 先前這裡是 `if (_currentUser == null) return;`：本機沒有個人資料時，按下 SOS 完全沒有
    // 反應 —— 不送出、不報錯、也沒有任何提示。求救的人會以為已經送出去了。
    final user = _currentUser;
    if (user == null) {
      _showMessage('找不到你的個人資料，無法送出求救。請重新登入後再試。', _sosRed);
      return;
    }

    setState(() => _isSending = true);
    try {
      final position = await _positionNow();
      final sent = await _publisher.raiseSos(user, lat: position?.latitude, lng: position?.longitude);
      final delivery = sent.delivery;
      if (delivery.failed) {
        // 誰都沒收到：不算舉起，按鈕維持可以再按。
        _showMessage(sosDeliveryMessage(delivery), _sosRed);
        return;
      }

      if (!mounted) return;
      setState(() {
        _sos = sent.sos;
        _delivery = delivery;
        _sentPosition = position;
      });
      if (!_isFullyDelivered(delivery)) _showMessage(sosDeliveryMessage(delivery), _caveat);
      if (delivery.reachedSomeone) _playSuccessSound();
      final queued = sent.queuedUpload;
      if (queued != null) {
        unawaited(_followQueuedUpload(queued, announce: !delivery.reachedSomeone));
      }
    } catch (e) {
      debugPrint('raise SOS failed: $e');
      _showMessage('發送失敗，請再試一次。', _sosRed);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }

    // 送出的這段時間裡定位已經回來的話，現在補送。
    unawaited(_sendLateLocation());
  }

  /// 剛舉起的 SOS 送出時沒有位置、或用的是系統記得的舊位置，定位現在回來了：再送一份帶 SOS 的
  /// 回報補上位置（#81）。Status 不變，雲端只改位置，協助者的認領不受影響。
  Future<void> _sendLateLocation() async {
    final user = _currentUser;
    final fix = _position;
    if (user == null || _delivery == null || fix == null || !_raised || _isSending) return;
    final sentAt = _sentPosition;
    if (sentAt != null && sentAt.latitude == fix.latitude && sentAt.longitude == fix.longitude) {
      return;
    }

    _sentPosition = fix; // 只補這一次；之後的定位更新不再重送
    setState(() => _isSending = true);
    try {
      final sent = await _publisher.addSosLocation(user, lat: fix.latitude, lng: fix.longitude);
      final followUp = sent.delivery;
      if (!mounted || !followUp.reachedSomeone) return;
      // 位置補上了；兩條路的但書以這次為準。
      setState(() => _delivery = followUp);
      _showMessage('已補上位置。', _green);
      final queued = sent.queuedUpload;
      if (queued != null) unawaited(_followQueuedUpload(queued, announce: false));
    } catch (e) {
      debugPrint('send late SOS location failed: $e');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// 撤回 SOS（#82）：確認之後回報安全、不帶 SOS（[withdrawSos]）。
  Future<void> _withdrawSos() async {
    final user = _currentUser;
    if (user == null || _isSending) return;

    if (await _confirmWithdraw() != true) return;

    setState(() => _isSending = true);
    try {
      final position = await _positionNow();
      final sent = await _publisher.withdrawSos(user, lat: position?.latitude, lng: position?.longitude);
      final delivery = sent.delivery;
      if (delivery.failed) {
        // 誰都沒收到撤回：附近的人與雲端都還看到 SOS，畫面不能說已撤回。
        _showMessage('撤回失敗，SOS 仍在。${reportDeliveryMessage(delivery, sent.status)}', _sosRed);
        return;
      }
      final queued = sent.queuedUpload;
      if (queued != null) unawaited(_followQueuedWithdrawal(queued));

      if (!mounted) return;
      setState(() {
        _sos = sent.sos;
        _delivery = null;
        _sentPosition = null;
      });
      _showMessage(
        '已撤回 SOS。${reportDeliveryMessage(delivery, sent.status)}',
        delivery.complete ? _green : _caveat,
      );
    } catch (e) {
      debugPrint('withdraw SOS failed: $e');
      _showMessage('撤回失敗，請再試一次。', _sosRed);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// 撤回 SOS 就是回報安全（[withdrawSos]），附近的人與雲端都會看到：先確認一次，免得誤按。
  Future<bool?> _confirmWithdraw() => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('撤回 SOS？'),
          content: const Text('撤回 SOS 會同時回報你目前「安全」，附近的人與救援者都會看到。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('我已安全，撤回'),
            ),
          ],
        ),
      );

  /// 離線暫存的上傳之後送到或失敗，畫面都要跟著更新。
  ///
  /// 送到了：橫幅不能一直停在「雲端尚未上傳」；[announce] 時（之前沒有任何人收到）現在才播
  /// 成功音效。失敗了（例如權限被擋）：只記 log 的話，求救的人會一直以為恢復連線就會送出。
  Future<void> _followQueuedUpload(Future<HealthReportDelivery> queued, {required bool announce}) async {
    final failure = (await queued).uploadFailure;
    if (!mounted) return;
    final current = _delivery;
    if (current != null && current.uploadQueued) {
      setState(() => _delivery = current.withUpload(failure: failure));
    }
    if (failure != null) {
      _showMessage('暫存的求救沒有上傳到雲端。', _sosRed);
    } else if (announce) {
      _playSuccessSound();
    }
  }

  /// 撤回的上傳之後才失敗：雲端上的人還看到 SOS，要讓他知道。
  Future<void> _followQueuedWithdrawal(Future<HealthReportDelivery> queued) async {
    if ((await queued).uploadFailure != null) _showMessage('暫存的撤回沒有上傳到雲端。', _sosRed);
  }

  /// 兩條路都送到，也附上了位置。少一樣都有但書，畫面不給全綠。
  static bool _isFullyDelivered(HealthReportDelivery delivery) => delivery.complete && delivery.withLocation;

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _showMessage(String message, Color color) {
    if (!mounted) return null;
    // SnackBar 是排隊一個一個顯示的。不先收掉舊的，送出結果要等前面的提示播完才看得到。
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    return messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: color,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// 上方橫幅的顏色。送出但「有但書」（離線暫存、廣播失敗、沒有位置）時不給全綠 ——
  /// 綠色會讓人以為救援端已經完整收到，包含位置。
  Color get _statusColor {
    if (!_raised) return _sosRed;
    final delivery = _delivery;
    if (delivery == null) return _sosRed;
    return _isFullyDelivered(delivery) ? _green : _caveat;
  }

  /// 上方橫幅的文字。送出之後要照實說明兩條路各自的狀況，以及有沒有附上位置。
  String get _statusMessage {
    if (!_raised) return '長按下方按鈕 3 秒發出求救訊號';
    // 之前就舉著、這次進來還沒送過：不知道當時送到哪裡，只說 SOS 還在。
    final delivery = _delivery;
    return delivery != null ? sosDeliveryMessage(delivery) : 'SOS 舉起中：之後的每份健康回報都會帶著 SOS，直到撤回或回報「安全」。';
  }

  String get _locationText {
    if (_isLoadingLocation) return '取得位置中…';
    if (_position == null) return '無法取得位置';
    return '${_position!.latitude.toStringAsFixed(4)}, ${_position!.longitude.toStringAsFixed(4)}';
  }

  /// SOS 舉起的時間。不是今天舉起的要連日期一起說，免得以為是剛剛。
  String get _sentTimeText {
    final raisedAt = _sos.raisedAt?.toLocal();
    if (raisedAt == null) return '尚未發送';
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(raisedAt.hour)}:${two(raisedAt.minute)}';
    final now = DateTime.now();
    final today = raisedAt.year == now.year && raisedAt.month == now.month && raisedAt.day == now.day;
    return today ? time : '${raisedAt.month}/${raisedAt.day} $time';
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
                      !_raised
                          ? Icons.info_outline_rounded
                          : (_delivery != null && _isFullyDelivered(_delivery!))
                              ? Icons.check_circle_rounded
                              : Icons.warning_amber_rounded,
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
                label: _raised ? 'SOS 已發送' : 'SOS 緊急求救，長按 3 秒送出',
                // 讀螢幕軟體沒有「按住 3 秒」的手勢，改用長按動作直接送出。
                onLongPress: _canHold ? _raiseSos : null,
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
                  // 撤回會送出一份不帶 SOS 的回報，附近的人與雲端都會看到（#82）。
                  if (_raised)
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: _isSending ? null : _withdrawSos,
                        child: const Text(
                          '撤回 SOS',
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

    final baseColor = _raised ? const Color(0xFF9E9690) : _sosRed;
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
                          _raised ? Icons.check_rounded : Icons.sos_rounded,
                          color: Colors.white,
                          size: 52,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _raised ? '已發送' : '長按 3 秒',
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
