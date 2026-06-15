import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'home_screen.dart';
import 'register_screen.dart';
import 'verify_email_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _bg = Color(0xFFF7F3EC);
  static const _brown = Color(0xFF5C3D2E);
  static const _brownLight = Color(0xFF8B5E3C);
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

      final user = credential.user;
      if (user == null) throw Exception('登入失敗');

      // 信箱尚未驗證：導回驗證頁（不允許進入 App）
      if (!user.emailVerified) {
        final prefs = await SharedPreferences.getInstance();
        final pendingJson = prefs.getString('pending_app_user');
        if (pendingJson != null && mounted) {
          final pendingUser = AppUser.fromJson(jsonDecode(pendingJson));
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => VerifyEmailScreen(pendingUser: pendingUser)),
          );
        } else {
          setState(() => _errorMessage = '您的電子郵件尚未驗證，請查收信箱中的驗證連結後再登入。');
        }
        return;
      }

      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get()
            .timeout(const Duration(seconds: 5));

        if (doc.exists && doc.data() != null) {
          final appUser = AppUser.fromJson(doc.data()!);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('app_user', jsonEncode(appUser.toJson()));
        }
      } catch (_) {}

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
      body: Column(
        children: [
          // 上方 Logo 區塊
          _TopHeader(),

          // 下方表單區域
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),

                    // 電子郵件
                    TextFormField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: '電子郵件',
                        filled: false,
                        prefixIcon:
                            const Icon(Icons.email_outlined, color: _brown),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                              color: _brown.withValues(alpha: 0.15), width: 1),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: _brown, width: 2),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return '請輸入電子郵件';
                        if (!v.contains('@')) return '請輸入正確的電子郵件格式';
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),

                    // 密碼
                    TextFormField(
                      controller: _passwordCtrl,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: '密碼',
                        filled: false,
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
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                              color: _brown.withValues(alpha: 0.15), width: 1),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: _brown, width: 2),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return '請輸入密碼';
                        if (v.length < 6) return '密碼至少需要 6 個字元';
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),

                    // 錯誤訊息
                    if (_errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                              color: Colors.red.shade700, fontSize: 13),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // 登入按鈕
                    ElevatedButton(
                      onPressed: _isLoading ? null : _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _brown,
                        foregroundColor: _bg,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        elevation: 2,
                        disabledBackgroundColor: _brown.withValues(alpha: 0.4),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2),
                            )
                          : const Text(
                              '登入',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                    const SizedBox(height: 20),

                    // 分隔線
                    Row(
                      children: [
                        Expanded(
                            child: Divider(
                                color: _brownLight.withValues(alpha: 0.2))),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('還沒有帳號？',
                              style: TextStyle(
                                  fontSize: 12, color: _textSecondary)),
                        ),
                        Expanded(
                            child: Divider(
                                color: _brownLight.withValues(alpha: 0.2))),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 註冊按鈕
                    OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                              builder: (_) => const RegisterScreen()),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _brown,
                        side: const BorderSide(color: _brown, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text(
                        '立即註冊',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 28),
        child: Column(
          children: [
            Image.asset(
              'assets/images/logo.png',
              width: 100,
              height: 100,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 14),
            const Text(
              '歡迎回來 👋',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Color(0xFF8C7B6E),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '防災小助理',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Color(0xFF5C3D2E),
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '登入帳號，與我們一起互助備災',
              style: TextStyle(fontSize: 13, color: Color(0xFF8C7B6E)),
            ),
          ],
        ),
      ),
    );
  }
}
