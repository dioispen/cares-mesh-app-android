import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'home_screen.dart';
import 'login_screen.dart';

class VerifyEmailScreen extends StatefulWidget {
  final AppUser pendingUser;

  const VerifyEmailScreen({super.key, required this.pendingUser});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  static const _bg = Color(0xFFF7F3EC);
  static const _brown = Color(0xFF5C3D2E);
  static const _textSecondary = Color(0xFF8C7B6E);

  bool _isChecking = false;
  bool _isResending = false;
  String? _message;

  Future<void> _checkVerified() async {
    setState(() {
      _isChecking = true;
      _message = null;
    });

    try {
      await FirebaseAuth.instance.currentUser?.reload();
      final user = FirebaseAuth.instance.currentUser;

      if (user != null && user.emailVerified) {
        // 信箱已驗證，儲存資料到本地與 Firestore
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('app_user', jsonEncode(widget.pendingUser.toJson()));

        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.pendingUser.id)
            .set(widget.pendingUser.toJson());

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          );
        }
      } else {
        setState(() => _message = '尚未驗證，請先點擊信件中的連結後再試。');
      }
    } catch (e) {
      setState(() => _message = '檢查失敗，請稍後再試。');
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<void> _resendEmail() async {
    setState(() {
      _isResending = true;
      _message = null;
    });

    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      setState(() => _message = '驗證信已重新寄出，請查收信箱。');
    } catch (e) {
      setState(() => _message = '寄送失敗，請稍後再試。');
    } finally {
      if (mounted) setState(() => _isResending = false);
    }
  }

  Future<void> _cancel() async {
    // 取消註冊：刪除剛建立的 Firebase Auth 帳號
    try {
      await FirebaseAuth.instance.currentUser?.delete();
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.mark_email_unread_rounded, size: 80, color: _brown),
                const SizedBox(height: 24),
                const Text(
                  '請驗證您的信箱',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _brown),
                ),
                const SizedBox(height: 12),
                Text(
                  '驗證信已寄送至\n${widget.pendingUser.email ?? "您的信箱"}\n\n請點擊信件中的連結完成驗證後，再按下方按鈕繼續。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, color: _textSecondary, height: 1.6),
                ),
                const SizedBox(height: 32),

                // 訊息提示
                if (_message != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _message!.contains('已重新') || _message!.contains('已驗證')
                          ? const Color(0xFF7AA67A).withValues(alpha: 0.1)
                          : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _message!.contains('已重新') || _message!.contains('已驗證')
                            ? const Color(0xFF7AA67A)
                            : Colors.red.shade200,
                      ),
                    ),
                    child: Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: _message!.contains('已重新') || _message!.contains('已驗證')
                            ? const Color(0xFF4A7A4A)
                            : Colors.red.shade700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 已驗證按鈕
                ElevatedButton(
                  onPressed: _isChecking ? null : _checkVerified,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _brown,
                    foregroundColor: _bg,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    disabledBackgroundColor: _brown.withValues(alpha: 0.5),
                  ),
                  child: _isChecking
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text('我已驗證，繼續',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 12),

                // 重新發送
                OutlinedButton(
                  onPressed: _isResending ? null : _resendEmail,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _brown,
                    side: const BorderSide(color: _brown),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isResending
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(color: _brown, strokeWidth: 2),
                        )
                      : const Text('重新發送驗證信', style: TextStyle(fontSize: 15)),
                ),
                const SizedBox(height: 24),

                // 取消
                TextButton(
                  onPressed: _cancel,
                  child: const Text('取消註冊', style: TextStyle(color: _textSecondary, fontSize: 14)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
