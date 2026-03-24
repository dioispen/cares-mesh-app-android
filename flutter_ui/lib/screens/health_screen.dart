import 'dart:math';
import 'package:flutter/material.dart';

// ── 求助任務狀態 ─────────────────────────────────────────
enum TaskStatus { pending, helped }

// ── 求助任務模型 ─────────────────────────────────────────
class EmergencyTask {
  final String id;
  final String type;        // '輕傷' or '重傷'
  final String? note;
  final DateTime reportedAt;
  final double lat;
  final double lng;
  TaskStatus status;

  EmergencyTask({
    required this.id,
    required this.type,
    this.note,
    required this.reportedAt,
    required this.lat,
    required this.lng,
    this.status = TaskStatus.pending,
  });
}

// ── 距離計算 ─────────────────────────────────────────────
double _calcDistKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
          sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

// ── 模擬附近求助任務 ─────────────────────────────────────
final _demoTasks = <EmergencyTask>[
  EmergencyTask(
    id: 't1', type: '重傷', note: '腿部骨折，無法移動',
    reportedAt: DateTime.now().subtract(const Duration(minutes: 8)),
    lat: 23.9638, lng: 120.9675,
  ),
  EmergencyTask(
    id: 't2', type: '輕傷', note: '頭部撞傷，意識清醒',
    reportedAt: DateTime.now().subtract(const Duration(minutes: 18)),
    lat: 23.9652, lng: 120.9690,
  ),
  EmergencyTask(
    id: 't3', type: '重傷', note: '',
    reportedAt: DateTime.now().subtract(const Duration(minutes: 30, hours: 0)),
    lat: 23.9625, lng: 120.9660,
  ),
  EmergencyTask(
    id: 't4', type: '輕傷', note: '',
    reportedAt: DateTime.now().subtract(const Duration(minutes: 44)),
    lat: 23.9610, lng: 120.9700,
  ),
  EmergencyTask(
    id: 't5', type: '重傷', note: '呼吸困難',
    reportedAt: DateTime.now().subtract(const Duration(hours: 1, minutes: 5)),
    lat: 23.9670, lng: 120.9650,
  ),
];

// 假設使用者目前位置（測試用）
const _myLat = 23.962;
const _myLng = 120.969;

// ── 主畫面 ───────────────────────────────────────────────
class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _green = Color(0xFF7AA67A);

  late final TabController _tabController;
  String _myStatus = '尚未回報';
  final List<EmergencyTask> _tasks = List.from(_demoTasks);

  static const _statusOptions = [
    {
      'label': '安全',
      'desc': '本人平安，無需協助',
      'icon': Icons.check_circle_rounded,
      'color': Color(0xFF7AA67A),
      'publishTask': false,
    },
    {
      'label': '輕傷',
      'desc': '有輕微傷口，已向管理端回報，附近用戶可前來協助',
      'icon': Icons.medical_services_rounded,
      'color': Color(0xFFBF7A5A),
      'publishTask': true,
    },
    {
      'label': '重傷',
      'desc': '受傷嚴重，已向管理端回報，附近用戶可前來協助',
      'icon': Icons.emergency_rounded,
      'color': Color(0xFFC4553A),
      'publishTask': true,
    },
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // 計算每筆任務與使用者的距離
    for (final t in _tasks) {
      t.status = TaskStatus.pending;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Color _myStatusColor() {
    final match = _statusOptions.where((o) => o['label'] == _myStatus);
    return match.isEmpty ? _textSecondary : match.first['color'] as Color;
  }

  // 回報狀態 + 發布求助任務（輕傷/重傷）
  void _reportStatus(Map<String, dynamic> option) {
    final label = option['label'] as String;
    final publish = option['publishTask'] as bool;

    setState(() {
      _myStatus = label;
      // 若為輕傷/重傷，在附近任務中加入自己的任務
      if (publish) {
        _tasks.insert(
          0,
          EmergencyTask(
            id: 'my_${DateTime.now().millisecondsSinceEpoch}',
            type: label,
            note: '我自行回報',
            reportedAt: DateTime.now(),
            lat: _myLat,
            lng: _myLng,
          ),
        );
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(option['icon'] as IconData, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                publish
                    ? '已回報「$label」給管理端，並發布至附近求助任務'
                    : '已回報「$label」給管理端',
              ),
            ),
          ],
        ),
        backgroundColor: option['color'] as Color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('健康回報'),
        iconTheme: const IconThemeData(color: _textPrimary),
        bottom: TabBar(
          controller: _tabController,
          labelColor: _textPrimary,
          unselectedLabelColor: _textSecondary,
          indicatorColor: _green,
          tabs: const [
            Tab(icon: Icon(Icons.person_rounded), text: '我的狀態'),
            Tab(icon: Icon(Icons.people_rounded), text: '附近求助任務'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMyStatusTab(),
          _buildNearbyTasksTab(),
        ],
      ),
    );
  }

  // ── Tab 1：我的狀態 ──────────────────────────────────────
  Widget _buildMyStatusTab() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 目前狀態卡
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3D2C1E).withValues(alpha: 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _myStatusColor().withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _statusOptions.where((o) => o['label'] == _myStatus).isEmpty
                          ? Icons.help_outline_rounded
                          : _statusOptions
                              .firstWhere((o) => o['label'] == _myStatus)['icon']
                              as IconData,
                      color: _myStatusColor(),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('目前回報狀態',
                          style: TextStyle(fontSize: 12, color: _textSecondary)),
                      const SizedBox(height: 3),
                      Text(
                        _myStatus,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _myStatusColor(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // 說明
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _green.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 15, color: _green),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '回報「輕傷」或「重傷」時，附近用戶將看到你的求助任務',
                      style: TextStyle(fontSize: 12, color: _green),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '選擇狀態',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _textSecondary,
                    letterSpacing: 1.2),
              ),
            ),

            Expanded(
              child: ListView.separated(
                itemCount: _statusOptions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final option = _statusOptions[index];
                  final color = option['color'] as Color;
                  final isSelected = _myStatus == option['label'];
                  return GestureDetector(
                    onTap: () => _reportStatus(option),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? color.withValues(alpha: 0.08)
                            : _card,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected
                              ? color.withValues(alpha: 0.6)
                              : const Color(0xFFE8E0D5),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isSelected
                                ? color.withValues(alpha: 0.12)
                                : const Color(0xFF3D2C1E).withValues(alpha: 0.04),
                            blurRadius: isSelected ? 10 : 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(option['icon'] as IconData,
                                color: color, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  option['label'] as String,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: isSelected ? color : _textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  option['desc'] as String,
                                  style: const TextStyle(
                                      fontSize: 12, color: _textSecondary),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (isSelected)
                            Icon(Icons.check_circle_rounded,
                                color: color, size: 22)
                          else
                            const Icon(Icons.circle_outlined,
                                color: Color(0xFFE8E0D5), size: 22),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab 2：附近求助任務 ──────────────────────────────────
  Widget _buildNearbyTasksTab() {
    final pendingTasks =
        _tasks.where((t) => t.status == TaskStatus.pending).toList();

    return SafeArea(
      child: Column(
        children: [
          // 頂部摘要
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3D2C1E).withValues(alpha: 0.05),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.location_searching_rounded,
                      size: 18, color: Color(0xFFC4553A)),
                  const SizedBox(width: 8),
                  Text(
                    '附近共 ${pendingTasks.length} 個待協助任務',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _textPrimary),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          Expanded(
            child: pendingTasks.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.favorite_rounded,
                            size: 52,
                            color:
                                _textSecondary.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        const Text('附近目前無求助任務',
                            style: TextStyle(
                                fontSize: 15, color: _textSecondary)),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 4),
                    itemCount: pendingTasks.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final task = pendingTasks[index];
                      final dist = _calcDistKm(
                          _myLat, _myLng, task.lat, task.lng);
                      final isHeavy = task.type == '重傷';
                      final color = isHeavy
                          ? const Color(0xFFC4553A)
                          : const Color(0xFFBF7A5A);
                      final timeStr = _formatTime(task.reportedAt);

                      return Container(
                        decoration: BoxDecoration(
                          color: _card,
                          borderRadius: BorderRadius.circular(16),
                          border: Border(
                            left: BorderSide(color: color, width: 4),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF3D2C1E)
                                  .withValues(alpha: 0.05),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 3),
                                          decoration: BoxDecoration(
                                            color: color
                                                .withValues(alpha: 0.12),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                          child: Text(
                                            '類型：${task.type}',
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: color),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 7,
                                                  vertical: 3),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF8C7B6E)
                                                .withValues(alpha: 0.1),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                          child: const Text(
                                            'Pending',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: _textSecondary),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '描述：${task.note?.isNotEmpty == true ? task.note! : "（無描述）"}',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: _textSecondary),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      timeStr,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: _textSecondary),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () =>
                                    _showTaskDetail(task, dist, color),
                                style: TextButton.styleFrom(
                                  foregroundColor: color,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                ),
                                child: const Text('查看更多',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── 任務詳細底部面板 ─────────────────────────────────────
  void _showTaskDetail(EmergencyTask task, double distKm, Color typeColor) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        decoration: const BoxDecoration(
          color: Color(0xFFFEFDF9),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 拖曳條
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),

            const Text('急救任務詳情',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: _textPrimary)),
            const SizedBox(height: 16),

            // 任務狀態
            _DetailRow(
              icon: Icons.pending_actions_rounded,
              label: '任務狀態',
              value: '待協助（Pending）',
              valueColor: const Color(0xFFBF7A5A),
            ),
            // 急救類型
            _DetailRow(
              icon: Icons.emergency_rounded,
              label: '急救類型',
              value: task.type,
              valueColor: typeColor,
            ),
            // 描述
            _DetailRow(
              icon: Icons.notes_rounded,
              label: '描述',
              value: task.note?.isNotEmpty == true ? task.note! : '（無描述）',
            ),
            // 距離
            _DetailRow(
              icon: Icons.social_distance_rounded,
              label: '你與病患距離',
              value: distKm < 1
                  ? '約 ${(distKm * 1000).round()} 公尺'
                  : '約 ${distKm.toStringAsFixed(1)} 公里',
              valueColor: const Color(0xFF4A90D9),
            ),

            const SizedBox(height: 24),

            // 前往協助按鈕
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  setState(() => task.status = TaskStatus.helped);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Row(
                        children: [
                          Icon(Icons.check_circle_rounded,
                              color: Colors.white, size: 18),
                          SizedBox(width: 8),
                          Text('已回報管理端，謝謝你的協助！'),
                        ],
                      ),
                      backgroundColor: _green,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      margin: const EdgeInsets.all(16),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                },
                icon: const Icon(Icons.directions_walk_rounded),
                label: const Text('前往協助',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),

            const SizedBox(height: 8),
            const Center(
              child: Text(
                '按下「前往協助」後，將通知管理端你正前往協助',
                style: TextStyle(fontSize: 11, color: _textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '剛剛';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分鐘前';
    if (diff.inHours < 24) {
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }
}

// ── 詳情列 ───────────────────────────────────────────────
class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF8C7B6E)),
          const SizedBox(width: 10),
          SizedBox(
            width: 88,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF8C7B6E))),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: valueColor ?? const Color(0xFF3D2C1E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
