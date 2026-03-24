class HealthReport {
  final String reporterId;   // 回報者 ID
  final String name;         // 回報者姓名
  final String status;       // 健康狀態：'良好' / '輕傷' / '重傷' / '需救援'
  final String? description; // 補充說明（可選）
  final DateTime reportTime; // 回報時間

  HealthReport({
    required this.reporterId,
    required this.name,
    required this.status,
    this.description,
    required this.reportTime,
  });

  Map<String, dynamic> toJson() => {
        'reporterId': reporterId,
        'name': name,
        'status': status,
        'description': description,
        'reportTime': reportTime.toIso8601String(),
      };

  factory HealthReport.fromJson(Map<String, dynamic> json) => HealthReport(
        reporterId: json['reporterId'] as String,
        name: json['name'] as String,
        status: json['status'] as String,
        description: json['description'] as String?,
        reportTime: DateTime.parse(json['reportTime'] as String),
      );
}
