import 'package:flutter/material.dart';

import '../models/health_survey.dart';

/// 健康回報的完整調查表。
///
/// 與 SOS 刻意做出區別：SOS 是一顆長按就送出的求救鈕；這裡是情況沒那麼緊急時，
/// 分段填寫較完整的狀況，最上方也提醒有立即危險要改用 SOS。
class HealthSurveyForm extends StatefulWidget {
  /// 上一次回報的 Status；還沒回報過時為 null。
  final String? initialStatus;
  final HealthSurvey initialSurvey;
  final bool submitting;
  final void Function(String status, HealthSurvey survey) onSubmit;
  final VoidCallback onOpenSos;

  const HealthSurveyForm({
    super.key,
    required this.initialStatus,
    required this.initialSurvey,
    required this.submitting,
    required this.onSubmit,
    required this.onOpenSos,
  });

  @override
  State<HealthSurveyForm> createState() => _HealthSurveyFormState();
}

class _HealthSurveyFormState extends State<HealthSurveyForm> {
  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _green = Color(0xFF7AA67A);
  static const _orange = Color(0xFFBF7A5A);
  static const _red = Color(0xFFC4553A);
  static const _border = Color(0xFFE8E0D5);

  static const _statuses = [
    (label: '安全', desc: '平安，無需協助', icon: Icons.check_circle_rounded, color: _green),
    (label: '輕傷', desc: '輕微受傷，能自行處理', icon: Icons.medical_services_rounded, color: _orange),
    (label: '重傷', desc: '受傷嚴重，需要醫療', icon: Icons.emergency_rounded, color: _red),
  ];

  late String? _status = widget.initialStatus;
  late HealthSurvey _survey = widget.initialSurvey;
  late final _notesCtrl = TextEditingController(text: widget.initialSurvey.notes);
  String? _error;

  /// 使用者動過表單之後，從雲端讀回的上一次回報就不再覆蓋表單。
  bool _dirty = false;

  @override
  void didUpdateWidget(HealthSurveyForm old) {
    super.didUpdateWidget(old);
    // 從雲端讀回上一次的回報時（例如換手機登入）帶入表單；使用者已經開始填就不覆蓋。
    if (!_dirty &&
        (old.initialStatus != widget.initialStatus || old.initialSurvey != widget.initialSurvey)) {
      _status = widget.initialStatus;
      _survey = widget.initialSurvey;
      _notesCtrl.text = widget.initialSurvey.notes;
    }
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  void _update(void Function() change) {
    setState(() {
      _dirty = true;
      _error = null;
      change();
    });
  }

  List<String> _toggled(List<String> list, String value) =>
      list.contains(value) ? (List.of(list)..remove(value)) : [...list, value];

  void _submit() {
    final status = _status;
    if (status == null) {
      setState(() => _error = '請先選擇你目前的狀況');
      return;
    }
    if (status != '安全' && _survey.injuries.isEmpty) {
      setState(() => _error = '請勾選至少一項傷勢或不適');
      return;
    }
    final survey = _survey.forStatus(status).copyWith(notes: _notesCtrl.text);
    _dirty = false;
    widget.onSubmit(status, survey);
  }

  @override
  Widget build(BuildContext context) {
    final injured = _status == '輕傷' || _status == '重傷';
    var n = 0;
    String step() => '${++n}';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _sosBanner(),
        const SizedBox(height: 16),

        _section(step(), '你目前的狀況', required: true, child: _statusTiles()),

        if (injured)
          _section(
            step(),
            '傷勢或身體不適',
            hint: '可複選',
            required: true,
            child: _chips(
              _status == '重傷'
                  ? [...HealthSurvey.severeInjuryOptions, ...HealthSurvey.minorInjuryOptions]
                  : HealthSurvey.minorInjuryOptions,
              _survey.injuries,
              (v) => _update(() => _survey = _survey.copyWith(injuries: _toggled(_survey.injuries, v))),
            ),
          ),

        _section(step(), '行動能力',
            child: _single(HealthSurvey.mobilityOptions, _survey.mobility,
                (v) => _update(() => _survey = _survey.copyWith(mobility: v)))),

        _section(step(), '目前所在地點',
            hint: '定位會一併附上',
            child: _single(HealthSurvey.locationOptions, _survey.location,
                (v) => _update(() => _survey = _survey.copyWith(location: v)))),

        _section(step(), '同住或同行的人',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _companionStepper(),
                const SizedBox(height: 12),
                const Text('其中需要特別照顧的（可複選）',
                    style: TextStyle(fontSize: 12, color: _textSecondary)),
                const SizedBox(height: 8),
                _chips(HealthSurvey.vulnerableOptions, _survey.vulnerable,
                    (v) => _update(() => _survey = _survey.copyWith(vulnerable: _toggled(_survey.vulnerable, v))),
                    // 「只有我」時沒有同行的人可選；寵物不算在人數裡。
                    enabled: (v) => _survey.companions > 0 || !HealthSurvey.needsCompanion(v)),
              ],
            )),

        _section(step(), '住家狀況',
            child: _single(HealthSurvey.housingOptions, _survey.housing,
                (v) => _update(() => _survey = _survey.copyWith(housing: v)))),

        _section(step(), '目前最需要的協助',
            hint: '可複選',
            child: _chips(HealthSurvey.needOptions, _survey.needs,
                (v) => _update(() => _survey = _survey.copyWith(needs: _toggled(_survey.needs, v))))),

        _section(step(), '補充說明',
            hint: '選填',
            child: TextField(
              controller: _notesCtrl,
              onChanged: (_) => _dirty = true,
              maxLines: 4,
              minLines: 3,
              maxLength: 300,
              decoration: InputDecoration(
                hintText: '例如：家中長者需要每日服用的藥快用完了',
                hintStyle: const TextStyle(fontSize: 13, color: _textSecondary),
                filled: true,
                fillColor: _card,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _border)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _brown, width: 2)),
              ),
            )),

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
          const SizedBox(height: 12),
        ],

        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            onPressed: widget.submitting ? null : _submit,
            icon: widget.submitting
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded, size: 18),
            label: Text(widget.submitting ? '送出中…' : '送出健康回報',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _brown,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _brown.withValues(alpha: 0.5),
              disabledForegroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '狀況會向附近的人廣播。傷勢、行動能力、所在地點、人數、住家與需要的協助，登入的使用者都看得到，方便附近的人前來幫忙；需要特別照顧的人與補充說明，只有接下任務的認證救援者看得到。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: _textSecondary, height: 1.5),
        ),
      ],
    );
  }

  Widget _sosBanner() => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: _red.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _red.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: _red, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '健康回報用於非緊急時的狀況調查，幫助管理中心安排物資與關懷。有立即危險請直接按 SOS。',
                style: TextStyle(fontSize: 12.5, color: _textPrimary, height: 1.45),
              ),
            ),
            TextButton(
              onPressed: widget.onOpenSos,
              style: TextButton.styleFrom(foregroundColor: _red),
              child: const Text('前往 SOS', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      );

  Widget _section(String number, String title,
          {String? hint, bool required = false, required Widget child}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: _brown, shape: BoxShape.circle),
                  child: Text(number,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _textPrimary)),
                if (required) const Text(' *', style: TextStyle(color: _red, fontWeight: FontWeight.w800)),
                if (hint != null) ...[
                  const SizedBox(width: 6),
                  Text(hint, style: const TextStyle(fontSize: 12, color: _textSecondary)),
                ],
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );

  Widget _statusTiles() => Row(
        children: [
          for (final s in _statuses) ...[
            if (s != _statuses.first) const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: () => _update(() => _status = s.label),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                  decoration: BoxDecoration(
                    color: _status == s.label ? s.color.withValues(alpha: 0.12) : _card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _status == s.label ? s.color : _border,
                      width: _status == s.label ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(s.icon, color: s.color, size: 26),
                      const SizedBox(height: 4),
                      Text(s.label,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: _status == s.label ? s.color : _textPrimary)),
                      const SizedBox(height: 2),
                      Text(s.desc,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 10.5, color: _textSecondary)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      );

  Widget _chips(
    List<String> options,
    List<String> selected,
    ValueChanged<String> onTap, {
    bool Function(String option)? enabled,
  }) =>
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final o in options)
            FilterChip(
              label: Text(o),
              selected: selected.contains(o),
              onSelected: enabled == null || enabled(o) ? (_) => onTap(o) : null,
              showCheckmark: true,
              checkmarkColor: Colors.white,
              selectedColor: _brown,
              backgroundColor: _card,
              side: BorderSide(color: selected.contains(o) ? _brown : _border),
              labelStyle: TextStyle(
                fontSize: 13,
                color: selected.contains(o) ? Colors.white : _textPrimary,
                fontWeight: selected.contains(o) ? FontWeight.w700 : FontWeight.w500,
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
        ],
      );

  /// 單選：再點一次已選的選項可以取消。
  Widget _single(List<String> options, String? selected, ValueChanged<String?> onChanged) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final o in options)
            ChoiceChip(
              label: Text(o),
              selected: selected == o,
              onSelected: (on) => onChanged(on ? o : null),
              showCheckmark: false,
              selectedColor: _brown,
              backgroundColor: _card,
              side: BorderSide(color: selected == o ? _brown : _border),
              labelStyle: TextStyle(
                fontSize: 13,
                color: selected == o ? Colors.white : _textPrimary,
                fontWeight: selected == o ? FontWeight.w700 : FontWeight.w500,
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
        ],
      );

  Widget _companionStepper() {
    Widget button(IconData icon, VoidCallback? onTap) => IconButton.filledTonal(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          style: IconButton.styleFrom(
            backgroundColor: _brown.withValues(alpha: 0.08),
            foregroundColor: _brown,
            minimumSize: const Size(36, 36),
          ),
        );
    final c = _survey.companions;
    return Row(
      children: [
        button(Icons.remove_rounded,
            c > 0 ? () => _update(() => _survey = _survey.withCompanions(c - 1)) : null),
        SizedBox(
          width: 64,
          child: Text(c == 0 ? '只有我' : '$c 人',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _textPrimary)),
        ),
        button(Icons.add_rounded,
            c < 30 ? () => _update(() => _survey = _survey.withCompanions(c + 1)) : null),
        const SizedBox(width: 8),
        const Text('（不含自己）', style: TextStyle(fontSize: 12, color: _textSecondary)),
      ],
    );
  }
}
