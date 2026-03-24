import 'package:flutter/material.dart';
import '../services/sos_service.dart';

class SOSScreen extends StatefulWidget {
  const SOSScreen({super.key});

  @override
  State<SOSScreen> createState() => _SOSScreenState();
}

class _SOSScreenState extends State<SOSScreen> {
  final SOSService _sosService = SOSService();
  bool _sosSent = false;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _sosRed = Color(0xFFC4553A);

  void _sendSOS() {
    _sosService.sendSOS('user_001', 23.964, 120.967);
    setState(() => _sosSent = true);
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
                        _sosSent ? 'SOS 已發送，請保持冷靜等待救援。' : '長按下方按鈕發出求救訊號',
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
                onTap: _sosSent ? null : _sendSOS,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _sosSent ? const Color(0xFF9E9690) : _sosRed,
                    boxShadow: [
                      BoxShadow(
                        color: (_sosSent ? const Color(0xFF9E9690) : _sosRed).withValues(alpha: 0.35),
                        blurRadius: 36,
                        spreadRadius: 6,
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 外圈裝飾
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

              // 位置 & 電話資訊卡
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
                    _infoRow(Icons.location_on_rounded, '目前位置', '埔里鎮（23.964, 120.967）'),
                    const Divider(height: 20, color: Color(0xFFE8E0D5)),
                    _infoRow(Icons.phone_rounded, '緊急電話', '119 消防 ／ 110 警察'),
                    const Divider(height: 20, color: Color(0xFFE8E0D5)),
                    _infoRow(Icons.access_time_rounded, '發送時間', _sosSent ? _nowString() : '尚未發送'),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              if (_sosSent)
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => setState(() => _sosSent = false),
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
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _textPrimary)),
      ],
    );
  }

  String _nowString() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }
}
