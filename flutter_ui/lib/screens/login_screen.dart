import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'home_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _bg = Color(0xFFF7F3EC);
  static const _brown = Color(0xFF5C3D2E);
  static const _textSecondary = Color(0xFF8C7B6E);

  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );

      final uid = credential.user?.uid;
      if (uid == null) throw Exception('登入失敗');

      // 從 Firestore 載入使用者資料並儲存到本地
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get()
            .timeout(const Duration(seconds: 5));

        if (doc.exists && doc.data() != null) {
          final appUser = AppUser.fromJson(doc.data()!);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('app_user', jsonEncode(appUser.toJson()));
        }
      } catch (_) {
        // 網路問題時允許繼續（離線模式），不阻擋登入
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } on FirebaseAuthException catch (e) {
      String msg;
      switch (e.code) {
        case 'user-not-found':
          msg = '找不到此帳號，請確認電子郵件是否正確。';
          break;
        case 'wrong-password':
          msg = '密碼不正確，請重新輸入。';
          break;
        case 'invalid-credential':
        case 'invalid-email':
          msg = '帳號或密碼不正確，請重新確認。';
          break;
        case 'user-disabled':
          msg = '此帳號已被停用，請聯絡管理員。';
          break;
        case 'too-many-requests':
          msg = '嘗試次數過多，請稍後再試。';
          break;
        default:
          msg = '登入失敗，請稍後再試。';
      }
      setState(() => _errorMessage = msg);
    } catch (e) {
      setState(() => _errorMessage = '登入時發生錯誤，請稍後再試。');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.shield_rounded, size: 72, color: _brown),
                  const SizedBox(height: 16),
                  const Text(
                    '歡迎回來',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: _brown,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '請登入您的帳號以繼續',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: _textSecondary),
                  ),
                  const SizedBox(height: 40),

                  // 電子郵件欄位
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: '電子郵件',
                      prefixIcon: const Icon(Icons.email_outlined, color: _brown),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _brown, width: 2),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return '請輸入電子郵件';
                      if (!v.contains('@')) return '請輸入正確的電子郵件格式';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // 密碼欄位
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: '密碼',
                      prefixIcon:
                          const Icon(Icons.lock_outline, color: _brown),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                          color: _textSecondary,
                        ),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _brown, width: 2),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return '請輸入密碼';
                      if (v.length < 6) return '密碼至少需要 6 個字元';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // 錯誤訊息
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        _errorMessage!,
                        style:
                            TextStyle(color: Colors.red.shade700, fontSize: 14),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // 登入按鈕
                  ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _brown,
                      foregroundColor: _bg,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      disabledBackgroundColor: _brown.withValues(alpha: 0.5),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Text('登入',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 24),

                  // 去註冊的連結
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('還沒有帳號？',
                          style: TextStyle(color: _textSecondary)),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                                builder: (_) => const RegisterScreen()),
                          );
                        },
                        child: const Text(
                          '立即註冊',
                          style: TextStyle(
                              color: _brown, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
