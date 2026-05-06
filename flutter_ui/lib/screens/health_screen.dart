import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import '../models/user.dart';
import '../models/health_report.dart';
import '../bridge/bitchat_bridge.dart';

class HealthService {
  String status = 'unknown';
  void updateStatus(String newStatus) => status = newStatus;
  String getStatus() => status;
}

enum TaskStatus { waiting, accepted, done }

class MutualAidTask {
  final String id;
  final String name;
  final String userId;
  final String injury;
  final String location;
  final double distanceKm;
  final String note;
  TaskStatus status;
  final bool isBle;

  MutualAidTask({
    required this.id,
    required this.name,
    required this.userId,
    required this.injury,
    required this.location,
    required this.distanceKm,
    required this.note,
    this.status = TaskStatus.waiting,
    this.isBle = false,
  });
}

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> with SingleTickerProviderStateMixin {
  final HealthService _healthService = HealthService();
  String _selectedStatus = '尚未回報';
  String? _selectedSubInjury;
  late TabController _tabController;

  static const _minorSubOptions = [
    '擦傷', '割傷', '瘀傷 / 撞傷', '扭傷',
    '燙傷（輕度）', '頭暈 / 頭痛', '手指或腳趾骨折', '輕度呼吸不適',
  ];
  static const _severeSubOptions = [
    '四肢骨折', '大量出血', '嚴重燙傷', '頭部外傷',
    '胸腹部外傷', '脊椎傷害', '意識不清', '失去意識',
  ];

  Position? _currentPosition;
  String? _currentUserId;
  List<QueryDocumentSnapshot> _firestoreDocs = [];
  final List<MutualAidTask> _bleTasks = [];
  final Map<String, TaskStatus> _taskStatusOverrides = {};
  StreamSubscription<QuerySnapshot>? _tasksSubscription;
  StreamSubscription? _bridgeSubscription;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _green = Color(0xFF7AA67A);
  static const _orange = Color(0xFFBF7A5A);
  static const _red = Color(0xFFC4553A);
  static const _purple = Color(0xFF9B88B3);

  final List<Map<String, dynamic>> _statusOptions = [
    {
      'label': '安全',
      'desc': '本人平安，無需協助',
      'icon': Icons.check_circle_rounded,
      'color': const Color(0xFF7AA67A),
    },
    {
      'label': '輕傷',
      'desc': '有輕微傷口，能自行行動',
      'icon': Icons.medical_services_rounded,
      'color': const Color(0xFFBF7A5A),
    },
    {
      'label': '重傷',
      'desc': '受傷嚴重，需要醫療協助',
      'icon': Icons.emergency_rounded,
      'color': const Color(0xFFC4553A),
    },
  ];


  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadUserAndPosition();
    _subscribeToTasks();
    _listenToBridge();
  }

  @override
  void dispose() {
    _tasksSubscription?.cancel();
    _bridgeSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _listenToBridge() {
    _bridgeSubscription = BitchatBridge.events().listen((event) {
      if (event['type'] == 'disaster_report') {
        final reportData = event['report'];
        if (reportData != null) {
          final report = HealthReport.fromJson(Map<String, dynamic>.from(reportData));
          if (report.reporterId == _currentUserId) return;

          setState(() {
            // 檢查是否已存在
            final index = _bleTasks.indexWhere((t) => t.userId == report.reporterId);
            
            double distanceKm = 0;
            if (report.lat != null && report.lng != null && _currentPosition != null) {
              final meters = Geolocator.distanceBetween(
                _currentPosition!.latitude, _currentPosition!.longitude,
                report.lat!, report.lng!,
              );
              distanceKm = meters / 1000;
            }

            final newTask = MutualAidTask(
              id: 'ble_${report.reporterId}',
              name: report.name,
              userId: report.reporterId,
              injury: report.status,
              location: report.lat != null && report.lng != null
                  ? '緯度 ${report.lat!.toStringAsFixed(4)}, 經度 ${report.lng!.toStringAsFixed(4)}'
                  : '位置未提供',
              distanceKm: double.parse(distanceKm.toStringAsFixed(1)),
              note: report.description ?? '來自 BLE 廣播',
              isBle: true,
            );

            if (index >= 0) {
              _bleTasks[index] = newTask;
            } else {
              _bleTasks.add(newTask);
            }
          });
        }
      }
    });
  }

  Future<void> _loadUserAndPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('app_user');
    if (userJson != null) {
      final user = AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      if (mounted) setState(() => _currentUserId = user.id);
    }
    final savedStatus = prefs.getString('health_status');
    final savedSub = prefs.getString('health_sub_injury');
    if (mounted) {
      setState(() {
        if (savedStatus != null) _selectedStatus = savedStatus;
        _selectedSubInjury = savedSub;
      });
    }
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        final position = await Geolocator.getCurrentPosition();
        if (mounted) setState(() => _currentPosition = position);
      }
    } catch (_) {}
  }

  void _subscribeToTasks() {
    _tasksSubscription = FirebaseFirestore.instance
        .collection('health_reports')
        .where('status', whereIn: ['輕傷', '重傷'])
        .snapshots()
        .listen((snapshot) {
          if (mounted) setState(() => _firestoreDocs = snapshot.docs);
        });
  }

  List<MutualAidTask> _buildTaskList() {
    final List<MutualAidTask> allTasks = [];
    
    // Firestore 任務
    final firestoreTasks = _firestoreDocs
        .where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return data['reporterId'] != _currentUserId;
        })
        .map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final lat = (data['lat'] as num?)?.toDouble();
          final lng = (data['lng'] as num?)?.toDouble();

          double distanceKm = 0;
          if (lat != null && lng != null && _currentPosition != null) {
            final meters = Geolocator.distanceBetween(
              _currentPosition!.latitude, _currentPosition!.longitude,
              lat, lng,
            );
            distanceKm = meters / 1000;
          }

          return MutualAidTask(
            id: doc.id,
            name: data['name'] as String? ?? '未知',
            userId: data['reporterId'] as String? ?? '',
            injury: data['status'] as String? ?? '輕傷',
            location: lat != null && lng != null
                ? '緯度 ${lat.toStringAsFixed(4)}, 經度 ${lng.toStringAsFixed(4)}'
                : '位置未提供',
            distanceKm: double.parse(distanceKm.toStringAsFixed(1)),
            note: data['description'] as String? ?? '無補充說明',
            status: _taskStatusOverrides[doc.id] ?? TaskStatus.waiting,
          );
        });
    
    allTasks.addAll(firestoreTasks);

    // 加入 BLE 任務 (去重：如果同一個 UserID 已經有 Firestore 任務，以 Firestore 為主)
    for (var bleTask in _bleTasks) {
      if (!allTasks.any((t) => t.userId == bleTask.userId)) {
        bleTask.status = _taskStatusOverrides[bleTask.id] ?? TaskStatus.waiting;
        allTasks.add(bleTask);
      }
    }

    allTasks.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return allTasks;
  }

  Color _statusColor() {
    final match = _statusOptions.where((o) => o['label'] == _selectedStatus);
    return match.isEmpty ? _textSecondary : match.first['color'] as Color;
  }

  void _onStatusTap(String status) {
    if (status == '安全') {
      _select('安全', null);
      return;
    }
    final subOptions = status == '輕傷' ? _minorSubOptions : _severeSubOptions;
    final color = status == '輕傷' ? _orange : _red;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SubInjurySheet(
        title: status,
        subOptions: subOptions,
        color: color,
        onSelect: (sub) {
          Navigator.pop(context);
          _select(status, sub);
        },
      ),
    );
  }

  Future<void> _select(String status, String? subInjury) async {
    _healthService.updateStatus(status);
    setState(() {
      _selectedStatus = status;
      _selectedSubInjury = subInjury;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('health_status', status);
      if (subInjury != null) {
        await prefs.setString('health_sub_injury', subInjury);
      } else {
        await prefs.remove('health_sub_injury');
      }
      final userJson = prefs.getString('app_user');
      if (userJson == null) return;
      final user = AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);

      final report = HealthReport(
        reporterId: user.id,
        name: user.name,
        phone: user.phone,
        bloodType: user.bloodType,
        status: status,
        description: subInjury,
        lat: _currentPosition?.latitude,
        lng: _currentPosition?.longitude,
        reportTime: DateTime.now(),
      );

      final reportJson = report.toJson();

      // 如果受傷，則透過 BLE 廣播
      if (status == '輕傷' || status == '重傷') {
        await BitchatBridge.sendHealthReport(reportJson);
      }

      // 上傳到 Firebase (原本邏輯保留)
      await FirebaseFirestore.instance
          .collection('health_reports')
          .add(reportJson);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已回報：$status'),
            backgroundColor: _statusColor(),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('回報失敗：$e'),
            backgroundColor: _red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }
  }

  Color _injuryColor(String injury) {
    if (injury == '重傷') return _red;
    if (injury == '輕傷') return _orange;
    return _green;
  }

  IconData _injuryIcon(String injury) {
    if (injury == '重傷') return Icons.emergency_rounded;
    if (injury == '輕傷') return Icons.medical_services_rounded;
    return Icons.check_circle_rounded;
  }

  void _showTaskDetail(MutualAidTask task) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TaskDetailSheet(
        task: task,
        injuryColor: _injuryColor(task.injury),
        onAccept: () {
          setState(() => _taskStatusOverrides[task.id] = TaskStatus.accepted);
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已接受協助 ${task.name} 的任務'),
              backgroundColor: _purple,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.all(16),
            ),
          );
        },
        onDone: () {
          setState(() => _taskStatusOverrides[task.id] = TaskStatus.done);
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已完成協助 ${task.name}'),
              backgroundColor: _green,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.all(16),
            ),
          );
        },
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
          indicatorColor: _orange,
          indicatorWeight: 2.5,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          tabs: [
            const Tab(text: '我的狀態'),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('互救任務'),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: _red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_buildTaskList().where((t) => t.status == TaskStatus.waiting).length}',
                      style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMyStatusTab(),
          _buildMutualAidTab(),
        ],
      ),
    );
  }

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
                      color: _statusColor().withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _statusOptions.where((o) => o['label'] == _selectedStatus).isEmpty
                          ? Icons.help_outline_rounded
                          : _statusOptions.firstWhere((o) => o['label'] == _selectedStatus)['icon'] as IconData,
                      color: _statusColor(),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('目前回報狀態', style: TextStyle(fontSize: 12, color: _textSecondary)),
                      const SizedBox(height: 3),
                      Text(
                        _selectedStatus,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _statusColor(),
                        ),
                      ),
                      if (_selectedSubInjury != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _selectedSubInjury!,
                          style: TextStyle(fontSize: 13, color: _statusColor().withValues(alpha: 0.8)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '選擇狀態',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _textSecondary, letterSpacing: 1.2),
              ),
            ),

            Expanded(
              child: ListView.separated(
                itemCount: _statusOptions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final option = _statusOptions[index];
                  final color = option['color'] as Color;
                  final isSelected = _selectedStatus == option['label'];
                  return GestureDetector(
                    onTap: () => _onStatusTap(option['label'] as String),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: isSelected ? color.withValues(alpha: 0.08) : _card,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected ? color.withValues(alpha: 0.6) : const Color(0xFFE8E0D5),
                          width: 1.5,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.12),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ]
                            : [
                                BoxShadow(
                                  color: const Color(0xFF3D2C1E).withValues(alpha: 0.04),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
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
                            child: Icon(option['icon'] as IconData, color: color, size: 22),
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
                                  style: const TextStyle(fontSize: 12, color: _textSecondary),
                                ),
                              ],
                            ),
                          ),
                          if (isSelected)
                            Icon(Icons.check_circle_rounded, color: color, size: 22)
                          else
                            Icon(Icons.circle_outlined, color: const Color(0xFFE8E0D5), size: 22),
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

  Widget _buildMutualAidTab() {
    final tasks = _buildTaskList();
    final waiting = tasks.where((t) => t.status == TaskStatus.waiting).toList();
    final accepted = tasks.where((t) => t.status == TaskStatus.accepted).toList();
    final done = tasks.where((t) => t.status == TaskStatus.done).toList();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // 說明橫幅
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: _purple.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _purple.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.volunteer_activism_rounded, color: _purple, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '附近有人需要協助，請量力而為，確保自身安全後再行救援',
                    style: TextStyle(fontSize: 13, color: Color(0xFF6B5B82), height: 1.4),
                  ),
                ),
              ],
            ),
          ),

          if (waiting.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionLabel('待救援', waiting.length, _red),
            const SizedBox(height: 8),
            ...waiting.map((t) => _taskCard(t)),
          ],

          if (accepted.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionLabel('進行中', accepted.length, _purple),
            const SizedBox(height: 8),
            ...accepted.map((t) => _taskCard(t)),
          ],

          if (done.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionLabel('已完成', done.length, _green),
            const SizedBox(height: 8),
            ...done.map((t) => _taskCard(t)),
          ],

          if (tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: Center(
                child: Text('附近目前無求助任務', style: TextStyle(color: _textSecondary)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label, int count, Color color) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color, letterSpacing: 1)),
        const SizedBox(width: 6),
        Text('$count 筆', style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.7))),
      ],
    );
  }

  Widget _taskCard(MutualAidTask task) {
    final color = _injuryColor(task.injury);
    final isDone = task.status == TaskStatus.done;
    final isAccepted = task.status == TaskStatus.accepted;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: isDone ? null : () => _showTaskDetail(task),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDone ? _bg : _card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isAccepted ? _purple.withValues(alpha: 0.4) : const Color(0xFFE8E0D5),
              width: isAccepted ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3D2C1E).withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDone ? 0.06 : 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_injuryIcon(task.injury), color: color.withValues(alpha: isDone ? 0.4 : 1), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          task.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: isDone ? _textSecondary : _textPrimary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: isDone ? 0.06 : 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            task.injury,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: color.withValues(alpha: isDone ? 0.5 : 1),
                            ),
                          ),
                        ),
                        if (isAccepted) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: _purple.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '協助中',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _purple),
                            ),
                          ),
                        ],
                        if (task.isBle) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.bluetooth_audio_rounded, size: 14, color: Colors.blue),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(Icons.location_on_rounded, size: 12, color: _textSecondary.withValues(alpha: 0.7)),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            task.location,
                            style: TextStyle(fontSize: 12, color: _textSecondary.withValues(alpha: 0.8)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${task.distanceKm} km',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDone ? _textSecondary : _textPrimary,
                    ),
                  ),
                  if (!isDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Icon(Icons.chevron_right_rounded, color: _textSecondary, size: 18),
                    ),
                  if (isDone)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Icon(Icons.check_circle_rounded, color: _green.withValues(alpha: 0.5), size: 18),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskDetailSheet extends StatelessWidget {
  final MutualAidTask task;
  final Color injuryColor;
  final VoidCallback onAccept;
  final VoidCallback onDone;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _purple = Color(0xFF9B88B3);
  static const _green = Color(0xFF7AA67A);

  const _TaskDetailSheet({
    required this.task,
    required this.injuryColor,
    required this.onAccept,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final isAccepted = task.status == TaskStatus.accepted;

    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD6CCC2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 標題
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: injuryColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.person_rounded, color: injuryColor, size: 24),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _textPrimary)),
                  Text(task.userId, style: const TextStyle(fontSize: 11, color: _textSecondary)),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: injuryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: injuryColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  task.injury,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: injuryColor),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // 資訊卡
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
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
                _infoRow(Icons.location_on_rounded, '位置', task.location),
                const Divider(height: 18, color: Color(0xFFE8E0D5)),
                _infoRow(Icons.near_me_rounded, '距離', '${task.distanceKm} 公里'),
                if (task.isBle) ...[
                  const Divider(height: 18, color: Color(0xFFE8E0D5)),
                  _infoRow(Icons.bluetooth_audio_rounded, '來源', 'BLE 現場廣播'),
                ],
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 操作按鈕
          if (!isAccepted)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onAccept,
                icon: const Icon(Icons.volunteer_activism_rounded, size: 18),
                label: const Text('前往協助', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _purple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
              ),
            ),

          if (isAccepted) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onDone,
                icon: const Icon(Icons.check_circle_rounded, size: 18),
                label: const Text('完成協助', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: _textSecondary),
        const SizedBox(width: 8),
        Text('$label：', style: const TextStyle(fontSize: 13, color: _textSecondary)),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _textPrimary),
          ),
        ),
      ],
    );
  }
}

// ── 傷況細項選單 ──────────────────────────────────────────
class _SubInjurySheet extends StatelessWidget {
  final String title;
  final List<String> subOptions;
  final Color color;
  final ValueChanged<String> onSelect;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  const _SubInjurySheet({
    required this.title,
    required this.subOptions,
    required this.color,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: const Color(0xFFD6CCC2), borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
              ),
              const SizedBox(width: 10),
              const Text('請選擇傷況細項', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textPrimary)),
            ],
          ),
          const SizedBox(height: 6),
          Text('由輕到重排列，請選擇最符合的項目', style: TextStyle(fontSize: 12, color: _textSecondary.withValues(alpha: 0.7))),
          const SizedBox(height: 16),
          ...subOptions.asMap().entries.map((entry) {
            final i = entry.key;
            final sub = entry.value;
            // 嚴重程度漸層：前半段用較淡色，後半段用較深色
            final severity = (i / (subOptions.length - 1));
            final itemColor = Color.lerp(color.withValues(alpha: 0.6), color, severity)!;
            return GestureDetector(
              onTap: () => onSelect(sub),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: itemColor.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(color: itemColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Text(sub, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _textPrimary)),
                    const Spacer(),
                    Icon(Icons.chevron_right_rounded, color: _textSecondary.withValues(alpha: 0.4), size: 18),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
