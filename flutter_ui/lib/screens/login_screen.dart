import 'dart:async';
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
          msg = '密碼不正確，請重新輸入；忘記密碼可以點「忘記密碼？」重設。';
          break;
        case 'invalid-credential':
        case 'invalid-email':
          msg = '帳號或密碼不正確，請重新確認；忘記密碼可以點「忘記密碼？」重設。';
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

  void _showForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ForgotPasswordSheet(initialEmail: _emailCtrl.text.trim()),
    );
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
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _isLoading ? null : _showForgotPassword,
                        style: TextButton.styleFrom(
                          foregroundColor: _brownLight,
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        ),
                        child: const Text(
                          '忘記密碼？',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),

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
              'assets/images/mascot_hi.png',
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

// ── 忘記密碼：寄重設密碼信 ────────────────────────────────
/// 用 Firebase Auth 的 sendPasswordResetEmail 寄出重設連結；使用者點信中的連結，
/// 在 Firebase 的頁面設定新密碼，再回來用新密碼登入。App 端不經手新密碼。
class _ForgotPasswordSheet extends StatefulWidget {
  final String initialEmail;
  const _ForgotPasswordSheet({required this.initialEmail});

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  static const _brown = Color(0xFF5C3D2E);
  static const _green = Color(0xFF7AA67A);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  /// 兩次寄送之間至少隔這麼久，避免連點把信箱塞爆、也避免觸發 Firebase 的頻率限制。
  static const _resendCooldown = 60;

  final _formKey = GlobalKey<FormState>();
  late final _emailCtrl = TextEditingController(text: widget.initialEmail);
  bool _sending = false;
  String? _sentTo;
  String? _error;
  int _cooldown = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailCtrl.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = _resendCooldown);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailCtrl.text.trim();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      // 讓重設信與 Firebase 的重設頁面都用繁體中文。
      await FirebaseAuth.instance.setLanguageCode('zh-TW');
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      setState(() => _sentTo = email);
      _startCooldown();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.code) {
            'invalid-email' => '電子郵件格式不正確',
            // 專案若關閉了 email enumeration protection，Firebase 才會回這個；
            // 開著的話不論帳號存不存在都當作成功，畫面上的說明也照此寫。
            'user-not-found' => '找不到使用這個信箱的帳號，請確認是否輸入正確',
            'too-many-requests' => '寄送次數過多，請稍後再試',
            'network-request-failed' => '網路連線失敗，請確認網路後再試',
            _ => '寄送失敗（${e.code}），請稍後再試',
          });
    } catch (e) {
      if (mounted) setState(() => _error = '寄送失敗，請稍後再試');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sentTo != null;
    return Padding(
      // 鍵盤彈出時把面板往上推，輸入框才不會被蓋住。
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        decoration: const BoxDecoration(
          color: Color(0xFFFEFDF9),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '忘記密碼',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _textPrimary),
              ),
              const SizedBox(height: 6),
              const Text(
                '輸入註冊時使用的電子郵件，我們會寄一封重設密碼的信給你。點信中的連結即可設定新密碼。',
                style: TextStyle(fontSize: 13, color: _textSecondary, height: 1.5),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                autofocus: widget.initialEmail.isEmpty,
                enabled: !_sending,
                decoration: InputDecoration(
                  labelText: '電子郵件',
                  prefixIcon: const Icon(Icons.email_outlined, color: _brown),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: _brown.withValues(alpha: 0.15)),
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

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                ),
                const SizedBox(height: 14),
              ],

              if (sent) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _green.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.mark_email_read_rounded, color: _green, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          // 不說「已寄到你的帳號」：Firebase 為了不洩漏哪些信箱有註冊，
                          // 對不存在的帳號也會回成功。
                          '如果 $_sentTo 有註冊過帳號，重設密碼的信已經寄出。\n'
                          '請到信箱點連結設定新密碼；沒看到的話也找找垃圾郵件匣。',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF4F7A4F), height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              ElevatedButton(
                onPressed: _sending || _cooldown > 0 ? null : _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _brown,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  disabledBackgroundColor: _brown.withValues(alpha: 0.4),
                  disabledForegroundColor: Colors.white,
                ),
                child: _sending
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        _cooldown > 0
                            ? '重新寄送（$_cooldown 秒後）'
                            : (sent ? '重新寄送' : '寄送重設密碼信'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
              if (sent) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(foregroundColor: _brown),
                  child: const Text('設定好新密碼了，回到登入'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
