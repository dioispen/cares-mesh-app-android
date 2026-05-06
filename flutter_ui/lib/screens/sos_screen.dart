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
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (mounted) setState(() => _position = pos);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _sendSOS() async {
    if (_currentUser == null || _isSending) return;
    setState(() => _isSending = true);
    try {
      final lat = _position?.latitude ?? 0.0;
      final lng = _position?.longitude ?? 0.0;
      await _sosService.sendSOS(
        userId: _currentUser!.id,
        userName: _currentUser!.name,
        phone: _currentUser!.phone,
        lat: lat,
        lng: lng,
        bloodType: _currentUser!.bloodType,
        medicalInfo: _currentUser!.medicalInfo,
      );
      if (mounted) {
        setState(() {
          _sosSent = true;
          _sentAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('發送失敗：$e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: _sosRed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: _sosSent
                      ? const Color(0xFF7AA67A).withValues(alpha: 0.1)
                      : _sosRed.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _sosSent
                        ? const Color(0xFF7AA67A).withValues(alpha: 0.5)
                        : _sosRed.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _sosSent ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                      color: _sosSent ? const Color(0xFF7AA67A) : _sosRed,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _sosSent ? 'SOS 已發送，請保持冷靜等待救援。' : '點擊下方按鈕發出求救訊號',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _sosSent ? const Color(0xFF4A7A4A) : _sosRed,
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
                          ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 3)
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _sosSent ? Icons.check_rounded : Icons.sos_rounded,
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3D2C1E).withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    _infoRow(Icons.person_rounded, '姓名', _currentUser?.name ?? '載入中…'),
                    const Divider(height: 20, color: Color(0xFFE8E0D5)),
                    _infoRow(Icons.location_on_rounded, '目前位置', _locationText),
                    const Divider(height: 20, color: Color(0xFFE8E0D5)),
                    _infoRow(Icons.phone_rounded, '緊急電話', '119 消防 ／ 110 警察'),
                    const Divider(height: 20, color: Color(0xFFE8E0D5)),
                    _infoRow(Icons.access_time_rounded, '發送時間', _sentTimeText),
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
                    child: Text('重置', style: TextStyle(color: _textSecondary)),
                  ),
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
        Text(label, style: const TextStyle(fontSize: 13, color: _textSecondary)),
        const Spacer(),
        Text(value,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: _textPrimary)),
      ],
    );
  }
}
