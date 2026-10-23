/// 健康回報的完整調查內容（Detail Tier）。
///
/// 健康回報與 SOS 的定位不同：SOS 是「現在有立即危險」的一鍵求救；健康回報是情況沒那麼
/// 緊急的里民，填寫較完整的狀況調查，讓管理中心安排物資、醫療與關懷訪視。
///
/// 後端依 ADR-0005 的分級拆成兩半（docs/adr/0007-health-survey-fields-split-by-tier.md）：
///
/// * [toDetailMap] → `health_reports/{uid}.survey`（Detail Tier，任何登入帳號都讀得到）：
///   行動能力、所在地點類型、同行人數、住家狀況、最需要的協助——附近想幫忙的人在接任務
///   之前就需要知道要帶什麼、怎麼幫。
/// * [toSensitiveMap] → `health_report_sensitive/{uid}.surveySensitive`（Sensitive Tier）：身邊與本人
///   需要特別照顧的情況（會透露身心障礙、慢性病、懷孕）與自由文字的補充說明。
///
/// 傷勢不在 survey 裡，沿用 Detail Tier 的 `description`（見 [injurySummary]）。
/// 以上都**不進入 BLE 廣播**——廣播只帶 Status（ADR-0003）。
class HealthSurvey {
  /// 傷勢或身體不適（可複選）；Status 為「安全」時為空。
  final List<String> injuries;

  /// 行動能力，見 [mobilityOptions]。
  final String? mobility;

  /// 目前所在地點，見 [locationOptions]。
  final String? location;

  /// 同住或同行的人數（不含自己）。
  final int companions;

  /// 身邊需要特別照顧的人（可複選），見 [vulnerableOptions]。
  final List<String> vulnerable;

  /// Reporter 本人需要特別照顧的情況（可複選），見 [selfVulnerableOptions]。與 [vulnerable]
  /// 分開：救援者要分得出是本人還是同行的家人，[vulnerable] 也才能維持「同行的人之中」的意思。
  final List<String> selfVulnerable;

  /// 住家狀況，見 [housingOptions]。
  final String? housing;

  /// 目前最需要的協助（可複選），見 [needOptions]。
  final List<String> needs;

  /// 其他補充說明。
  final String notes;

  const HealthSurvey({
    this.injuries = const [],
    this.mobility,
    this.location,
    this.companions = 0,
    this.vulnerable = const [],
    this.selfVulnerable = const [],
    this.housing,
    this.needs = const [],
    this.notes = '',
  });

  static const minorInjuryOptions = [
    '擦傷', '割傷', '瘀傷 / 撞傷', '扭傷',
    '燙傷（輕度）', '頭暈 / 頭痛', '手指或腳趾骨折', '輕度呼吸不適',
  ];
  /// 傷勢都是本人自己填的，所以不放「失去意識」「意識不清」——那樣的人填不了這份表。
  /// 「曾短暫失去意識」是現在清醒的人填得出來、救援者又需要知道的（頭部外傷的警訊）。
  static const severeInjuryOptions = [
    '四肢骨折', '大量出血', '嚴重燙傷', '頭部外傷',
    '胸腹部外傷', '脊椎傷害', '曾短暫失去意識',
  ];

  /// 可能需要立即救援的傷勢。健康回報是非緊急的狀況調查，選到這些時要提醒，並讓 Reporter 選擇
  /// 一併舉起 SOS（SOS 是 Health Report 上的標記，ADR-0004）。
  static const urgentInjuryOptions = {'大量出血', '頭部外傷', '胸腹部外傷', '脊椎傷害', '曾短暫失去意識'};
  static const mobilityOptions = ['可自行行動', '需要協助才能移動', '無法移動'];
  static const locationOptions = ['家中', '避難所 / 收容處', '親友住處', '戶外或車上', '其他'];
  static const vulnerableOptions = ['長者', '幼童', '孕婦', '身心障礙者', '慢性病患', _pet];
  static const _pet = '寵物';

  /// 本人不會是幼童或寵物；行動不便另有「行動能力」一題。
  static const selfVulnerableOptions = ['長者', '孕婦', '身心障礙者', '慢性病患'];

  /// [vulnerableOptions] 裡除了寵物都是「同住或同行的人」之一：[companions] 為 0 時沒有對象。
  static bool needsCompanion(String option) => option != _pet;
  static const housingOptions = ['沒有損壞', '輕微損壞，仍可居住', '嚴重損壞，暫時無法居住', '不清楚'];
  static const needOptions = [
    '飲用水', '食物', '藥品', '醫療協助', '電力 / 充電',
    '保暖衣物', '臨時住所', '交通接送', '心理支持',
  ];

  /// 傷勢的簡短摘要，寫入回報的 `description`：互救任務把它當成協助者看到的備註，
  /// 意義與舊版「選一個傷勢」相同。
  String? get injurySummary => injuries.isEmpty ? null : injuries.join('、');

  /// 選了至少一項 [urgentInjuryOptions]。
  bool get hasUrgentInjury => injuries.any(urgentInjuryOptions.contains);

  HealthSurvey copyWith({
    List<String>? injuries,
    String? mobility,
    String? location,
    int? companions,
    List<String>? vulnerable,
    List<String>? selfVulnerable,
    String? housing,
    List<String>? needs,
    String? notes,
  }) =>
      HealthSurvey(
        injuries: injuries ?? this.injuries,
        mobility: mobility ?? this.mobility,
        location: location ?? this.location,
        companions: companions ?? this.companions,
        vulnerable: vulnerable ?? this.vulnerable,
        selfVulnerable: selfVulnerable ?? this.selfVulnerable,
        housing: housing ?? this.housing,
        needs: needs ?? this.needs,
        notes: notes ?? this.notes,
      );

  /// `health_reports/{uid}.survey`。鍵必須與 firestore.rules 的 detailSurveyKeys() 一致。
  Map<String, dynamic> toDetailMap() => {
        'mobility': mobility,
        'location': location,
        'companions': companions,
        'housing': housing,
        'needs': needs,
      };

  /// `health_report_sensitive/{uid}.surveySensitive`。鍵必須與 firestore.rules 的 sensitiveSurveyKeys() 一致。
  Map<String, dynamic> toSensitiveMap() => {
        'vulnerable': vulnerable,
        'selfVulnerable': selfVulnerable,
        'notes': notes.trim().isEmpty ? null : notes.trim(),
      };

  /// 從自己上一次的回報組回表單內容。[description] 是 Detail Tier 的傷勢摘要，拆回清單時
  /// 只保留認得的選項。欄位缺漏或型別不對時退回預設值，不讓一筆舊文件弄壞表單。
  factory HealthSurvey.fromMaps({
    String? description,
    Map<String, dynamic>? detail,
    Map<String, dynamic>? sensitive,
  }) {
    List<String> list(Object? v) => v is List ? v.whereType<String>().toList() : const [];
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    const known = {...minorInjuryOptions, ...severeInjuryOptions};
    return HealthSurvey(
      injuries: (description ?? '').split('、').where(known.contains).toList(),
      mobility: str(detail?['mobility']),
      location: str(detail?['location']),
      companions: detail?['companions'] is int ? detail!['companions'] as int : 0,
      housing: str(detail?['housing']),
      needs: list(detail?['needs']),
      vulnerable: list(sensitive?['vulnerable']),
      selfVulnerable: list(sensitive?['selfVulnerable']),
      notes: str(sensitive?['notes']) ?? '',
    );
  }

  /// 只換掉 Sensitive Tier 那一半（本人另外讀回 health_report_sensitive 時用）。
  HealthSurvey withSensitive(Map<String, dynamic>? sensitive) {
    final s = HealthSurvey.fromMaps(sensitive: sensitive);
    return copyWith(vulnerable: s.vulnerable, selfVulnerable: s.selfVulnerable, notes: s.notes);
  }

  /// 改同住或同行的人數。改成 0 時，需要特別照顧的「人」已經沒有對象，一併清掉；寵物不算在人數裡，保留。
  HealthSurvey withCompanions(int companions) => copyWith(
        companions: companions,
        vulnerable: companions == 0 ? vulnerable.where((v) => !needsCompanion(v)).toList() : vulnerable,
      );

  /// 換成「安全」時傷勢不再適用；換成「輕傷」時只有重傷才有的傷勢不再適用（表單也不再顯示，
  /// 留著就會送出使用者看不到的選項）。其餘調查內容（人數、需求等）保留。
  HealthSurvey forStatus(String status) => switch (status) {
        '安全' => copyWith(injuries: const []),
        '輕傷' => copyWith(injuries: injuries.where(minorInjuryOptions.contains).toList()),
        _ => this,
      };
}
