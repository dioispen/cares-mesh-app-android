import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/sos_service.dart';

class SOSScreen extends StatefulWidget {
  const SOSScreen({super.key});

  @override
  State<SOSScreen> createState() => _SOSScreenState();
}

class _SOSScreenState extends State<SOSScreen> {
  final SOSService _sosService = SOSService();

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

  @override
  void initState() {
    super.initState();
    _loadUser();
    _fetchLocation();
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
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _sendSOS() async {
    if (_isSending) return;

    // 先前這裡是 `if (_currentUser == null) return;`：本機沒有個人資料時，
    // 按下 SOS 完全沒有反應 —— 不送出、不報錯、也沒有任何提示。求救的人
    // 會以為已經送出去了。
    final user = _currentUser;
    if (user == null) {
      _showMessage('找不到你的個人資料，無法送出求救。請重新登入後再試。', _sosRed);
      return;
    }

    setState(() => _isSending = true);
    try {
      // 拿不到定位就送 null。座標是救援端唯一能用來找人的欄位，寧可明確地
      // 「沒有位置」，也不要送一個看起來合理、實際上錯得離譜的 0, 0。
      final send = _sosService.sendSOS(
        userId: user.id,
        userName: user.name,
        phone: user.phone,
        lat: _position?.latitude,
        lng: _position?.longitude,
        bloodType: user.bloodType,
        medicalInfo: user.medicalInfo,
      );

      // Firestore 的寫入要等伺服器確認才完成，離線時永遠不會完成（資料已進
      // 本機佇列，恢復連線會自動送出）。求救的人不能對著一顆轉不停的按鈕等，
      // 所以逾時就照實說明狀況。
      var queuedOffline = false;
      try {
        await send.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        queuedOffline = true;
        unawaited(send.catchError((Object e) {
          debugPrint('queued SOS failed: $e');
          return '';
        }));
      }

      if (!mounted) return;
      setState(() {
        _sosSent = true;
        _sentAt = DateTime.now();
        _queuedOffline = queuedOffline;
      });

      if (queuedOffline) {
        _showMessage('目前離線，求救已暫存，恢復連線後會自動送出。', const Color(0xFFBF7A5A));
      } else if (_position == null) {
        _showMessage('求救已送出，但沒有附上位置。請盡量用其他方式告知所在地。', const Color(0xFFBF7A5A));
      }
    } catch (e) {
      debugPrint('sendSOS failed: $e');
      if (mounted) _showMessage('發送失敗，請再試一次。', _sosRed);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _showMessage(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
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
    if (_queuedOffline || _position == null) return const Color(0xFFBF7A5A);
    return const Color(0xFF7AA67A);
  }

  /// 上方橫幅的文字。送出之後要照實說明狀況：離線暫存、以及有沒有附上位置，
  /// 都直接影響求救的人接下來該怎麼做。
  String get _statusMessage {
    if (!_sosSent) return '點擊下方按鈕發出求救訊號';
    if (_queuedOffline) return '目前離線，求救已暫存，恢復連線後會自動送出。';
    if (_position == null) return 'SOS 已發送，但沒有附上位置，請設法告知所在地。';
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
        child: Padding(
          padding: const EdgeInsets.all(20),
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
                          : (_queuedOffline || _position == null
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

              // SOS 大圓按鈕
              GestureDetector(
                onTap: _sosSent || _isSending ? null : _sendSOS,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _sosSent ? const Color(0xFF9E9690) : _sosRed,
                    boxShadow: [
                      BoxShadow(
                        color: (_sosSent ? const Color(0xFF9E9690) : _sosRed)
                            .withValues(alpha: 0.35),
                        blurRadius: 36,
                        spreadRadius: 6,
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
                      _isSending
                          ? const CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _sosSent
                                      ? Icons.check_rounded
                                      : Icons.sos_rounded,
                                  color: Colors.white,
                                  size: 52,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _sosSent ? '已發送' : 'SOS',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 3,
                                  ),
                                ),
                              ],
                            ),
                    ],
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

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _textSecondary),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: _textSecondary),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _textPrimary,
          ),
        ),
      ],
    );
  }
}
