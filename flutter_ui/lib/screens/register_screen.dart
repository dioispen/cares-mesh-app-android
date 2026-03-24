import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'home_screen.dart';

const _prefsKeyUser = 'app_user';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  static const _bg = Color(0xFFF7F3EC);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _brown = Color(0xFF5C3D2E);

  final _pageController = PageController();
  int _currentStep = 0;
  bool _isSaving = false;

  // Step 1：基本資料
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _areaCtrl = TextEditingController();
  final _step1Key = GlobalKey<FormState>();

  // Step 2：緊急聯絡人
  final _ecNameCtrl = TextEditingController();
  final _ecPhoneCtrl = TextEditingController();
  final _ecRelationCtrl = TextEditingController();
  final _step2Key = GlobalKey<FormState>();

  // Step 3：健康資訊（可選）
  String? _bloodType;
  final _medicalCtrl = TextEditingController();

  @override
  void dispose() {
    _pageController.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _areaCtrl.dispose();
    _ecNameCtrl.dispose();
    _ecPhoneCtrl.dispose();
    _ecRelationCtrl.dispose();
    _medicalCtrl.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_currentStep == 0 && !_step1Key.currentState!.validate()) return;
    if (_currentStep == 1 && !_step2Key.currentState!.validate()) return;

    if (_currentStep < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
      setState(() => _currentStep++);
    } else {
      _submit();
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
      setState(() => _currentStep--);
    }
  }

  Future<void> _submit() async {
    setState(() => _isSaving = true);
    try {
      final user = AppUser(
        id: AppUser.generateId(),
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        area: _areaCtrl.text.trim(),
        emergencyContactName: _ecNameCtrl.text.trim(),
        emergencyContactPhone: _ecPhoneCtrl.text.trim(),
        emergencyContactRelation: _ecRelationCtrl.text.trim(),
        bloodType: _bloodType,
        medicalInfo: _medicalCtrl.text.trim().isEmpty ? null : _medicalCtrl.text.trim(),
        registeredAt: DateTime.now(),
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyUser, jsonEncode(user.toJson()));

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── 頂部進度列 ──
            _StepHeader(currentStep: _currentStep),

            // ── 頁面內容 ──
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _Step1BasicInfo(
                    formKey: _step1Key,
                    nameCtrl: _nameCtrl,
                    phoneCtrl: _phoneCtrl,
                    areaCtrl: _areaCtrl,
                  ),
                  _Step2EmergencyContact(
                    formKey: _step2Key,
                    nameCtrl: _ecNameCtrl,
                    phoneCtrl: _ecPhoneCtrl,
                    relationCtrl: _ecRelationCtrl,
                  ),
                  _Step3HealthInfo(
                    bloodType: _bloodType,
                    medicalCtrl: _medicalCtrl,
                    onBloodTypeChanged: (v) => setState(() => _bloodType = v),
                  ),
                ],
              ),
            ),

            // ── 底部按鈕 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _nextStep,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _brown,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              _currentStep < 2 ? '下一步' : '完成註冊',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                  if (_currentStep > 0) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _prevStep,
                      child: const Text('返回上一步', style: TextStyle(color: _textSecondary)),
                    ),
                  ],
                  if (_currentStep == 2) ...[
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _isSaving ? null : _submit,
                      child: Text('略過健康資訊，直接完成',
                          style: TextStyle(color: _textSecondary.withValues(alpha: 0.7), fontSize: 13)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 步驟標題列 ───────────────────────────────────────────
class _StepHeader extends StatelessWidget {
  final int currentStep;
  const _StepHeader({required this.currentStep});

  static const _steps = ['基本資料', '緊急聯絡人', '健康資訊'];
  static const _icons = [Icons.person_rounded, Icons.contact_phone_rounded, Icons.favorite_rounded];

  @override
  Widget build(BuildContext context) {
    const brown = Color(0xFF5C3D2E);
    const green = Color(0xFF7AA67A);
    const textSecondary = Color(0xFF8C7B6E);

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_rounded, color: brown, size: 22),
              const SizedBox(width: 8),
              const Text('防災 APP 註冊',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: brown)),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: List.generate(_steps.length, (i) {
              final isDone = i < currentStep;
              final isActive = i == currentStep;
              final color = isDone || isActive ? green : textSecondary.withValues(alpha: 0.3);

              return Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: isDone || isActive
                                  ? green.withValues(alpha: isActive ? 1 : 0.15)
                                  : Colors.transparent,
                              shape: BoxShape.circle,
                              border: Border.all(color: color, width: 1.5),
                            ),
                            child: Icon(
                              isDone ? Icons.check_rounded : _icons[i],
                              color: isDone ? Colors.white : color,
                              size: 20,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _steps[i],
                            style: TextStyle(
                              fontSize: 11,
                              color: isActive ? green : textSecondary.withValues(alpha: isDone ? 0.8 : 0.4),
                              fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (i < _steps.length - 1)
                      Expanded(
                        child: Container(
                          height: 1.5,
                          margin: const EdgeInsets.only(bottom: 22),
                          color: i < currentStep
                              ? green.withValues(alpha: 0.5)
                              : textSecondary.withValues(alpha: 0.2),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

// ── Step 1：基本資料 ──────────────────────────────────────
class _Step1BasicInfo extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController nameCtrl, phoneCtrl, areaCtrl;
  const _Step1BasicInfo({required this.formKey, required this.nameCtrl, required this.phoneCtrl, required this.areaCtrl});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('請輸入你的基本資料', '管理端在緊急狀況時將透過此資料聯繫你'),
            const SizedBox(height: 24),
            _InputField(
              label: '姓名',
              controller: nameCtrl,
              hint: '例：王小明',
              icon: Icons.person_outline_rounded,
              validator: (v) => (v == null || v.trim().isEmpty) ? '請輸入姓名' : null,
            ),
            const SizedBox(height: 16),
            _InputField(
              label: '手機號碼',
              controller: phoneCtrl,
              hint: '例：0912-345-678',
              icon: Icons.phone_outlined,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\-]'))],
              validator: (v) {
                if (v == null || v.trim().isEmpty) return '請輸入手機號碼';
                if (v.replaceAll('-', '').length < 9) return '手機號碼格式不正確';
                return null;
              },
            ),
            const SizedBox(height: 16),
            _InputField(
              label: '居住區域',
              controller: areaCtrl,
              hint: '例：南投縣埔里鎮',
              icon: Icons.location_on_outlined,
              validator: (v) => (v == null || v.trim().isEmpty) ? '請輸入居住區域' : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step 2：緊急聯絡人 ────────────────────────────────────
class _Step2EmergencyContact extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController nameCtrl, phoneCtrl, relationCtrl;
  const _Step2EmergencyContact({required this.formKey, required this.nameCtrl, required this.phoneCtrl, required this.relationCtrl});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('緊急聯絡人', '發生意外時，管理端將聯繫此人'),
            const SizedBox(height: 24),
            _InputField(
              label: '聯絡人姓名',
              controller: nameCtrl,
              hint: '例：王大明',
              icon: Icons.person_outline_rounded,
              validator: (v) => (v == null || v.trim().isEmpty) ? '請輸入聯絡人姓名' : null,
            ),
            const SizedBox(height: 16),
            _InputField(
              label: '聯絡人電話',
              controller: phoneCtrl,
              hint: '例：0923-456-789',
              icon: Icons.phone_outlined,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\-]'))],
              validator: (v) {
                if (v == null || v.trim().isEmpty) return '請輸入聯絡人電話';
                if (v.replaceAll('-', '').length < 9) return '電話號碼格式不正確';
                return null;
              },
            ),
            const SizedBox(height: 16),
            _InputField(
              label: '與你的關係',
              controller: relationCtrl,
              hint: '例：父親、配偶、朋友',
              icon: Icons.people_outline_rounded,
              validator: (v) => (v == null || v.trim().isEmpty) ? '請輸入與你的關係' : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step 3：健康資訊（可選）──────────────────────────────
class _Step3HealthInfo extends StatelessWidget {
  final String? bloodType;
  final TextEditingController medicalCtrl;
  final ValueChanged<String?> onBloodTypeChanged;

  const _Step3HealthInfo({
    required this.bloodType,
    required this.medicalCtrl,
    required this.onBloodTypeChanged,
  });

  static const _bloodTypes = ['A 型', 'B 型', 'O 型', 'AB 型', '不清楚'];

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF7AA67A);
    const textSecondary = Color(0xFF8C7B6E);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('健康資訊（可選填）', '提供給救援人員參考，有助於緊急救護'),
          const SizedBox(height: 24),

          // 血型選擇
          const Text('血型',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF3D2C1E))),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            children: _bloodTypes.map((bt) {
              final selected = bloodType == bt;
              return GestureDetector(
                onTap: () => onBloodTypeChanged(selected ? null : bt),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: selected ? green : Colors.transparent,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: selected ? green : textSecondary.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    bt,
                    style: TextStyle(
                      fontSize: 14,
                      color: selected ? Colors.white : textSecondary,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),

          // 慢性病 / 藥物過敏
          _InputField(
            label: '慢性病 / 藥物過敏',
            controller: medicalCtrl,
            hint: '例：糖尿病、青黴素過敏（無則留空）',
            icon: Icons.medical_information_outlined,
            maxLines: 3,
          ),

          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline_rounded, size: 15, color: Color(0xFF7AA67A)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '健康資訊僅供救援使用，不會用於其他用途',
                    style: TextStyle(fontSize: 12, color: Color(0xFF7AA67A)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 共用元件 ─────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  const _SectionTitle(this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF3D2C1E))),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(fontSize: 13, color: Color(0xFF8C7B6E))),
      ],
    );
  }
}

class _InputField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final int maxLines;

  const _InputField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF3D2C1E))),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 15, color: Color(0xFF3D2C1E)),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: const Color(0xFF8C7B6E).withValues(alpha: 0.6), fontSize: 14),
            prefixIcon: Icon(icon, size: 20, color: const Color(0xFF8C7B6E)),
            filled: true,
            fillColor: const Color(0xFFFEFDF9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: const Color(0xFF8C7B6E).withValues(alpha: 0.2)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: const Color(0xFF8C7B6E).withValues(alpha: 0.2)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF7AA67A), width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFBF7A5A)),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFBF7A5A), width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          ),
        ),
      ],
    );
  }
}
