import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import '../models/user.dart';
import '../models/health_report.dart';
import '../bridge/bitchat_bridge.dart';
import '../protocol/ble_packet_decoder.dart';
import '../services/mascot_service.dart';
import '../services/mutual_aid_tasks.dart';

// Top-level function required by compute() — must live outside any class.
HealthReportPayload? _decodeHealthReportPayload(List<int> payload) =>
    HealthReportPayload.decode(payload);
    
class HealthService {
  String status = 'unknown';
  void updateStatus(String newStatus) => status = newStatus;
  String getStatus() => status;
}

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen>
    with SingleTickerProviderStateMixin, RouteAware {
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
  String? _myBroadcastHandle;
  Future<String>? _broadcastHandleFuture;
  List<ReportEntry> _reports = [];
  final List<MutualAidTask> _bleTasks = [];
  final Map<String, TaskStatus> _taskStatusOverrides = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _tasksSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _ownReportSubscription;
  StreamSubscription? _bridgeSubscription;

  /// 第一批任務資料還沒到 vs. 真的沒有任務——這兩件事要分開講，
  /// 否則載入中的空畫面會寫著「附近目前無求助任務」。
  bool _tasksLoaded = false;
  String? _tasksError;

  /// 回報送出中：擋住連點造成的重複廣播與互相覆蓋的寫入。
  bool _isSubmitting = false;

  /// 舊版隨機 ID 文件只補查一次，避免監聽每次觸發都打一次 query。
  bool _legacyRestoreAttempted = false;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    mascotRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    mascotRouteObserver.unsubscribe(this);
    _tasksSubscription?.cancel();
    _ownReportSubscription?.cancel();
    _bridgeSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  // RouteObserver 會在路由安裝的那一幀回呼，這時直接寫 notifier 會在 build 期間
  // 觸發 markNeedsBuild（log 裡的 setState() called during build）。延到下一幀再寫。
  @override
  void didPush() => _setMascotOptions();

  @override
  void didPopNext() => _setMascotOptions();

  void _setMascotOptions() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) mascotOptionsNotifier.value = healthOptions;
    });
  }

  void _listenToBridge() {
    _bridgeSubscription = BitchatBridge.events().listen((event) async {
      // 統一封包格式：Android 直接轉發原始封包，Flutter 負責解析
      if (event['type'] != 'packet') return;
      if ((event['packetType'] as num?)?.toInt() != BlePacketType.healthReport) return;

      final rawPayload = event['payload'];
      if (rawPayload == null) return;

      final payload = List<int>.from(rawPayload as List);

      // 在背景 isolate 解碼二進位 payload，避免佔用 UI thread
      final decoded = await compute(_decodeHealthReportPayload, payload);
      if (decoded == null) return;
      if (!mounted) return;

      // 不顯示自己發出的報告（Broadcast Tier 沒有帳號 ID，以廣播 handle 比對）。
      // handle 是非同步載入的，還沒備好就比對會把自己的廣播當成別人的求助，
      // 所以這裡等它產生／讀取完成再判斷。
      final myHandle = _myBroadcastHandle ??
          await _getOrCreateBroadcastHandle(
              await SharedPreferences.getInstance());
      if (decoded.reporterHandle == myHandle) return;
      if (!mounted) return;

      final report = decoded.toBroadcastReport();
      final position = _currentPosition;
      final hasLocation = report.approxLat != null && report.approxLng != null;

      final newTask = MutualAidTask(
        id: 'ble_${report.reporterHandle}',
        name: '匿名回報 ${report.reporterHandle.substring(0, 4)}',
        userId: report.reporterHandle,
        injury: report.status,
        location: hasLocation
            ? '概略位置 ${report.approxLat!.toStringAsFixed(2)}, ${report.approxLng!.toStringAsFixed(2)}'
            : '位置未提供',
        distanceKm: distanceKmBetween(
          position?.latitude,
          position?.longitude,
          report.approxLat,
          report.approxLng,
        ),
        note: '來自 BLE 廣播・聯絡資訊需另行請求',
        isBle: true,
      );

      setState(() {
        final index = _bleTasks.indexWhere((t) => t.userId == newTask.userId);
        if (index >= 0) {
          _bleTasks[index] = newTask;
        } else {
          _bleTasks.add(newTask);
        }
      });
    }, onError: (Object e) {
      // 沒有原生端的平台（iOS 模擬機、桌機）會丟 MissingPluginException。
      // 收不到 BLE 廣播不影響 Firestore 那條路，記錄下來就好，不要變成未處理例外。
      debugPrint('bitchat bridge stream unavailable: $e');
    });
  }

  /// 取得（或首次產生）本機的廣播 handle。
  ///
  /// 這是刻意**不從帳號衍生**的隨機值：不用 Firebase UID、電話或姓名雜湊，
  /// 讓長期側錄者無法把 handle 反推回本人或 Firestore 文件（ADR-0003）。
  /// 一經產生即固定，供接收端過濾自己的回報用。
  ///
  /// 用 [_broadcastHandleFuture] memoize，確保 initState 與使用者點擊兩條 async 路徑
  /// 不會各自產生並寫入不同的隨機值。
  Future<String> _getOrCreateBroadcastHandle(SharedPreferences prefs) {
    return _broadcastHandleFuture ??= _loadOrCreateBroadcastHandle(prefs);
  }

  Future<String> _loadOrCreateBroadcastHandle(SharedPreferences prefs) async {
    var handle = prefs.getString('broadcast_handle');
    if (handle == null || !RegExp(r'^[0-9a-f]{12}$').hasMatch(handle)) {
      final rng = Random.secure();
      handle = List<String>.generate(
        6,
        (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await prefs.setString('broadcast_handle', handle);
    }
    return handle;
  }

  /// 「我的狀態」是每個帳號各自的資料，所以本機快取的鍵值必須綁 uid。
  ///
  /// 舊版存在不分帳號的 'health_status'／'health_sub_injury' 裡：同一台裝置
  /// A 帳號回報「輕傷／割傷」後登出，B 帳號登入時會讀到同一份值，看起來像兩個
  /// 帳號的健康狀態被同步了。
  static const _legacyStatusKey = 'health_status';
  static const _legacySubInjuryKey = 'health_sub_injury';
  static String _statusKey(String uid) => 'health_status:$uid';
  static String _subInjuryKey(String uid) => 'health_sub_injury:$uid';

  /// 舊文件清理只需要成功一次，之後不再重複查詢。
  static String _prunedKey(String uid) => 'health_reports_pruned:$uid';

  Future<void> _loadUserAndPosition() async {
    final prefs = await SharedPreferences.getInstance();

    // 舊的不分帳號鍵值無從判斷屬於誰，一律清掉，免得洩漏給下一個登入的帳號。
    await prefs.remove(_legacyStatusKey);
    await prefs.remove(_legacySubInjuryKey);

    final userJson = prefs.getString('app_user');
    final user = userJson == null
        ? null
        : AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
    if (user != null && mounted) setState(() => _currentUserId = user.id);

    final handle = await _getOrCreateBroadcastHandle(prefs);
    if (mounted) setState(() => _myBroadcastHandle = handle);

    if (user != null) {
      final savedStatus = prefs.getString(_statusKey(user.id));
      final savedSub = prefs.getString(_subInjuryKey(user.id));
      if (mounted) {
        setState(() {
          if (savedStatus != null) _selectedStatus = savedStatus;
          _selectedSubInjury = savedSub;
        });
      }
      // 監聽只是掛上去、不等網路，所以搶在定位之前接好：位置權限對話框停在
      // 那裡的時候，「我的狀態」不該跟著卡住。
      _subscribeToOwnReport(user.id);
    }

    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        final position = await Geolocator.getCurrentPosition()
            .timeout(const Duration(seconds: 5));
        if (mounted) setState(() => _currentPosition = position);
      }
    } catch (_) {}
  }

  /// 訂閱自己那份回報文件，讓「我的狀態」以後端為準。
  ///
  /// 一人一筆之後文件 ID 就是 uid，所以這裡只讀自己的文件：換帳號登入不可能
  /// 看到別人的狀態，換裝置或從別的裝置改狀態也會同步過來。
  /// 本機快取只是監聽還沒回來前的離線初值。
  void _subscribeToOwnReport(String uid) {
    _ownReportSubscription?.cancel();
    _ownReportSubscription = FirebaseFirestore.instance
        .collection('health_reports')
        .doc(uid)
        .snapshots()
        .listen((doc) async {
      final data = doc.data();
      final status = data?['status'] as String?;
      if (!doc.exists || status == null) {
        // 後端沒有這份文件：可能是舊版 add() 留下隨機 ID 的回報，補查一次。
        // 查不到也不清掉本機顯示的狀態——寧可留著待確認的傷勢，也不要把
        // 使用者的回報悄悄降級成「尚未回報」。
        await _restoreLegacyOwnStatus(uid);
        return;
      }
      final subInjury = data?['description'] as String?;
      _healthService.updateStatus(status);
      if (mounted) {
        setState(() {
          _selectedStatus = status;
          _selectedSubInjury = subInjury;
        });
      }
      await _cacheOwnStatus(uid, status, subInjury);
    }, onError: (Object e) => debugPrint('own report stream failed: $e'));
  }

  /// 補查舊版 add() 流程留下的自己的回報（文件 ID 不是 uid 的那些）。
  ///
  /// 只讀 reporterId 等於自己的文件。失敗（離線、權限）就維持現狀，不阻擋畫面。
  Future<void> _restoreLegacyOwnStatus(String uid) async {
    if (_legacyRestoreAttempted) return;
    _legacyRestoreAttempted = true;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('health_reports')
          .where('reporterId', isEqualTo: uid)
          .get()
          .timeout(const Duration(seconds: 5));
      if (snapshot.docs.isEmpty) return;

      // reportTime 是 ISO8601 字串，字典序等於時間序。這裡刻意不用 orderBy：
      // 等式條件 + 排序會需要額外的複合索引，而自己的回報筆數很少，在本機挑最新的即可。
      final latest = snapshot.docs.reduce((a, b) {
        final at = a.data()['reportTime'] as String? ?? '';
        final bt = b.data()['reportTime'] as String? ?? '';
        return at.compareTo(bt) >= 0 ? a : b;
      });
      final status = latest.data()['status'] as String?;
      if (status == null) return;
      final subInjury = latest.data()['description'] as String?;

      _healthService.updateStatus(status);
      if (mounted) {
        setState(() {
          _selectedStatus = status;
          _selectedSubInjury = subInjury;
        });
      }
      await _cacheOwnStatus(uid, status, subInjury);
    } catch (_) {}
  }

  /// 刪掉自己在舊版 add() 流程留下的多餘回報（文件 ID 不等於 uid 的那些）。
  ///
  /// 只動 reporterId 等於自己的文件，這也是 firestore.rules 唯一允許刪除的範圍。
  /// 失敗（離線、權限）就跳過，不影響這次回報。
  Future<void> _pruneLegacyOwnReports(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prunedKey(uid)) == true) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('health_reports')
          .where('reporterId', isEqualTo: uid)
          .get()
          .timeout(const Duration(seconds: 5));
      final stale = snapshot.docs.where((doc) => doc.id != uid).toList();
      if (stale.isNotEmpty) {
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in stale) {
          batch.delete(doc.reference);
        }
        await batch.commit().timeout(const Duration(seconds: 10));
      }
      // 清完才記錄，失敗的話下次回報會再試一次。
      await prefs.setBool(_prunedKey(uid), true);
    } catch (e) {
      debugPrint('pruneLegacyOwnReports failed: $e');
    }
  }

  Future<void> _cacheOwnStatus(String uid, String status, String? subInjury) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_statusKey(uid), status);
    if (subInjury != null) {
      await prefs.setString(_subInjuryKey(uid), subInjury);
    } else {
      await prefs.remove(_subInjuryKey(uid));
    }
  }

  /// 把任務狀態寫回 Firestore，讓被協助者與其他協助者看到同一份進度。
  ///
  /// 先前這裡只改 [_taskStatusOverrides]（純記憶體 Map），所以「已接受／已完成」
  /// 既不會同步給別人，App 重開也會整批退回等待中。
  ///
  /// BLE 任務沒有對應的 Firestore 文件——它只存在於現場廣播——因此仍走本機覆寫。
  Future<void> _updateTaskStatus(
    MutualAidTask task,
    TaskStatus next,
    String successMessage,
    Color successColor,
  ) async {
    if (task.isBle) {
      setState(() => _taskStatusOverrides[task.id] = next);
      _showTaskSnackBar(successMessage, successColor);
      return;
    }

    // 規則要求 helperId 必須等於 request.auth.uid，沒有本機使用者就一定會被擋，
    // 與其讓使用者看到 permission-denied，不如直接說明原因。
    if (_currentUserId == null) {
      _showTaskSnackBar('請先完成註冊驗證，才能接任務', _red);
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('health_reports')
          .doc(task.id)
          .update({
        'taskStatus': next.name,
        'helperId': next == TaskStatus.waiting ? null : _currentUserId,
      });
      // 不必 setState：snapshots() 監聽會帶回新狀態並重繪。
      _showTaskSnackBar(successMessage, successColor);
    } catch (e) {
      debugPrint('updateTaskStatus failed: $e');
      _showTaskSnackBar(
        next == TaskStatus.accepted
            ? '接任務失敗，可能已被其他夥伴接走'
            : '更新任務狀態失敗，請稍後再試',
        _red,
      );
    }
  }

  void _showTaskSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _subscribeToTasks() {
    _tasksSubscription = FirebaseFirestore.instance
        .collection('health_reports')
        .where('status', whereIn: mutualAidInjuries.toList())
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      setState(() {
        _reports = [
          for (final doc in snapshot.docs)
            (id: doc.id, data: doc.data()),
        ];
        _tasksLoaded = true;
        _tasksError = null;
      });
    }, onError: (Object e) {
      debugPrint('health_reports stream failed: $e');
      if (!mounted) return;
      // 讀取失敗要說出來。沿用「附近目前無求助任務」會讓人以為現場沒人需要幫忙。
      setState(() {
        _tasksLoaded = true;
        _tasksError = '任務清單載入失敗，請檢查網路後重新進入此頁';
      });
    });
  }

  List<MutualAidTask> _buildTaskList() => buildMutualAidTasks(
        reports: _reports,
        bleTasks: _bleTasks,
        currentUserId: _currentUserId,
        myLat: _currentPosition?.latitude,
        myLng: _currentPosition?.longitude,
        bleStatusOverrides: _taskStatusOverrides,
      );

  Color _statusColor() {
    final match = _statusOptions.where((o) => o['label'] == _selectedStatus);
    return match.isEmpty ? _textSecondary : match.first['color'] as Color;
  }

  void _onStatusTap(String status) {
    if (_isSubmitting) return;
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

  /// 送出一筆健康回報：BLE 廣播、Firestore、本機快取三條路各自獨立。
  ///
  /// 災難現場可能只有 BLE 沒有網路，也可能有網路但裝置不支援 BLE，
  /// 所以任一條失敗都不能拖垮其他兩條。
  Future<void> _select(String status, String? subInjury) async {
    // 連點防護：重複送出會重複廣播，兩次寫入也會互相覆蓋。
    if (_isSubmitting) return;

    final previousStatus = _selectedStatus;
    final previousSubInjury = _selectedSubInjury;

    _healthService.updateStatus(status);
    setState(() {
      _isSubmitting = true;
      _selectedStatus = status;
      _selectedSubInjury = subInjury;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final userJson = prefs.getString('app_user');
      if (userJson == null) {
        // 不知道這筆狀態屬於哪個帳號時，既不快取也不送出；畫面也要還原，
        // 否則會顯示一個其實沒有回報成功的狀態。
        _revertStatus(previousStatus, previousSubInjury);
        _showTaskSnackBar('尚未登入，無法回報健康狀態', _red);
        return;
      }
      final user = AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);

      final handle = _myBroadcastHandle ?? await _getOrCreateBroadcastHandle(prefs);
      if (mounted && _myBroadcastHandle == null) {
        setState(() => _myBroadcastHandle = handle);
      }

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

      // BLE 廣播只送 Broadcast Tier：不具識別性的 handle、Status，以及原始座標
      // （由原生端就地降精度為 geohash）。姓名／電話／血型／自由文字一律不進入廣播（ADR-0003）。
      //
      // 自己包 try：沒開藍牙、裝置不支援、原生端拋錯，都不該讓雲端回報跟著失敗。
      var bleSent = true;
      try {
        await BitchatBridge.sendHealthReport({
          'reporterHandle': handle,
          'status': status,
          'lat': _currentPosition?.latitude,
          'lng': _currentPosition?.longitude,
        });
      } catch (e) {
        bleSent = false;
        debugPrint('sendHealthReport (BLE) failed: $e');
      }

      // Firestore 仍寫入完整回報（Reporter 對後端的自願揭露，另由 firestore.rules 治理）
      //
      // 一人一筆：文件 ID 就用 uid，改狀態是直接覆寫同一份文件，不再 add() 新增。
      // 舊做法每回報一次就多一筆，同一個人會在後端留下一串過期狀態（回報安全之後，
      // 之前那筆「輕傷」還在互救任務清單上）。
      //
      // 這裡刻意用不帶 merge 的 set()：taskStatus／helperId 不在 toJson() 裡，會一併被
      // 清掉，等於傷勢一改就回到「等待中／無人認領」。傷勢內容已經不一樣了，沿用舊的
      // 認領紀錄會讓協助者看到對不上的任務。
      final write = FirebaseFirestore.instance
          .collection('health_reports')
          .doc(user.id)
          .set(report.toJson());

      // set() 的 Future 要等伺服器確認才完成，離線時會一直不完成（資料已進本機佇列，
      // 恢復連線會自動送出）。所以不無限等待——災難時離線是常態，使用者需要立刻得到
      // 回饋，而不是一個永遠轉不完的按鈕。
      var queuedOffline = false;
      try {
        await write.timeout(const Duration(seconds: 6));
      } on TimeoutException {
        queuedOffline = true;
        // 佇列中的寫入之後才失敗的話，錯誤沒人接會變成未處理例外。
        unawaited(write.catchError((Object e) {
          debugPrint('queued health report failed: $e');
        }));
      }

      await _cacheOwnStatus(user.id, status, subInjury);

      if (!queuedOffline) {
        // 清掉舊版 add() 在後端留下的多餘文件。純後端整理，不讓它擋住回饋。
        unawaited(_pruneLegacyOwnReports(user.id));
      }

      if (!mounted) return;
      _showTaskSnackBar(
        switch ((queuedOffline, bleSent)) {
          (true, true) => '已記錄：$status（離線中，已藍牙廣播，恢復連線後自動上傳）',
          (true, false) => '已記錄：$status（目前離線，恢復連線後自動上傳）',
          (false, true) => '已回報：$status',
          (false, false) => '已回報：$status（藍牙廣播未送出）',
        },
        queuedOffline ? _orange : _statusColor(),
      );
    } catch (e) {
      // 寫入被規則擋下、或本機儲存失敗：後端根本沒有這筆，畫面不能顯示已回報。
      debugPrint('health report failed: $e');
      _revertStatus(previousStatus, previousSubInjury);
      _showTaskSnackBar('回報失敗，請稍後再試', _red);
    } finally {
      _isSubmitting = false;
      if (mounted) setState(() {});
    }
  }

  /// 回報沒成功時把畫面退回原本的狀態，不留下一個假的「已回報」。
  void _revertStatus(String previousStatus, String? previousSubInjury) {
    _healthService.updateStatus(previousStatus);
    if (!mounted) return;
    setState(() {
      _selectedStatus = previousStatus;
      _selectedSubInjury = previousSubInjury;
    });
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
        // 任務同步之後，看到「進行中」不代表是自己接的。BLE 任務只存在本機，
        // 沒有被別人先接走的問題。
        canComplete: task.isBle ||
            (_currentUserId != null && task.helperId == _currentUserId),
        onAccept: () {
          Navigator.pop(context);
          _updateTaskStatus(
              task, TaskStatus.accepted, '已接受協助 ${task.name} 的任務', _purple);
        },
        onDone: () {
          Navigator.pop(context);
          _updateTaskStatus(task, TaskStatus.done, '已完成協助 ${task.name}', _green);
        },
        // 接了卻趕不過去時要有出口，否則那筆求助會一直卡在「進行中」，
        // 別人也接不了。firestore.rules 的狀態機本來就允許本人退回等待中。
        onRelease: () {
          Navigator.pop(context);
          _updateTaskStatus(task, TaskStatus.waiting,
              '已放棄協助 ${task.name}，任務回到待救援', _orange);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 一次算好給 badge 與清單共用：組任務要算每一筆的距離，每次重繪算三遍很浪費。
    final tasks = _buildTaskList();

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
                      '${tasks.where((t) => t.status == TaskStatus.waiting).length}',
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
          _buildMutualAidTab(tasks),
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
                    onTap: _isSubmitting
                        ? null
                        : () => _onStatusTap(option['label'] as String),
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

  Widget _buildMutualAidTab(List<MutualAidTask> tasks) {
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
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Center(child: _emptyTaskListMessage()),
            ),
        ],
      ),
    );
  }

  /// 清單是空的有三種原因，訊息不能混用：還在載入、載入失敗、真的沒有人需要協助。
  Widget _emptyTaskListMessage() {
    if (_tasksError != null) {
      return Column(
        children: [
          const Icon(Icons.cloud_off_rounded, color: _textSecondary, size: 28),
          const SizedBox(height: 10),
          Text(
            _tasksError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _textSecondary),
          ),
        ],
      );
    }
    if (!_tasksLoaded) {
      return const Column(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: _textSecondary),
          ),
          SizedBox(height: 12),
          Text('載入附近的求助任務…', style: TextStyle(color: _textSecondary)),
        ],
      );
    }
    return const Text('附近目前無求助任務', style: TextStyle(color: _textSecondary));
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
                    task.distanceLabel,
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
  /// 這位使用者是不是當初認領的人——只有他能按「完成協助」。
  final bool canComplete;
  final VoidCallback onAccept;
  final VoidCallback onDone;
  final VoidCallback onRelease;

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _purple = Color(0xFF9B88B3);
  static const _green = Color(0xFF7AA67A);

  const _TaskDetailSheet({
    required this.task,
    required this.injuryColor,
    required this.canComplete,
    required this.onAccept,
    required this.onDone,
    required this.onRelease,
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
                _infoRow(Icons.near_me_rounded, '距離', task.distanceLabel),
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

          if (isAccepted && !canComplete)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: _purple.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _purple.withValues(alpha: 0.3)),
              ),
              child: const Text(
                '已由其他夥伴接手協助中',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _purple),
              ),
            ),

          if (isAccepted && canComplete) ...[
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
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onRelease,
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('放棄協助', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _textSecondary,
                  side: const BorderSide(color: Color(0xFFD6CCC2)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '放棄後這筆求助會回到待救援，讓其他夥伴可以接手',
              style: TextStyle(fontSize: 12, color: _textSecondary),
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
