import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:dio_cache_interceptor_hive_store/dio_cache_interceptor_hive_store.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ── 防空洞資料模型 ─────────────────────────────────────────
class Shelter {
  final String name;
  final double lat;
  final double lng;
  final String capacity;
  final String status;
  double? distanceKm; // 執行時計算

  Shelter({
    required this.name,
    required this.lat,
    required this.lng,
    required this.capacity,
    required this.status,
    this.distanceKm,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'lat': lat,
        'lng': lng,
        'capacity': capacity,
        'status': status,
      };

  factory Shelter.fromJson(Map<String, dynamic> json) => Shelter(
        name: json['name'] as String,
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        capacity: json['capacity'] as String,
        status: json['status'] as String,
      );
}

// ── 模擬伺服器資料（上線時替換為 API 呼叫）────────────────
final _serverShelters = [
  Shelter(name: '埔里地下停車場', lat: 23.964, lng: 120.967, capacity: '500 人', status: '開放中'),
  Shelter(name: '南投縣政府防空洞', lat: 23.960, lng: 120.972, capacity: '300 人', status: '開放中'),
  Shelter(name: '埔里鎮公所地下室', lat: 23.961, lng: 120.969, capacity: '200 人', status: '開放中'),
  Shelter(name: '埔里國中地下室', lat: 23.967, lng: 120.965, capacity: '400 人', status: '即將滿員'),
  Shelter(name: '愛蘭國小避難所', lat: 23.955, lng: 120.970, capacity: '250 人', status: '開放中'),
];

const _prefsKeyShelters = 'offline_shelters';
const _prefsKeyUpdatedAt = 'shelters_updated_at';
const _prefsKeyLocHistory = 'location_history'; // [{lat, lng}]

// ── 距離計算（Haversine 公式）────────────────────────────
double _calcDistKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

// ── 主畫面 ─────────────────────────────────────────────────
class ShelterScreen extends StatefulWidget {
  const ShelterScreen({super.key});

  @override
  State<ShelterScreen> createState() => _ShelterScreenState();
}

class _ShelterScreenState extends State<ShelterScreen> with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);
  static const _green = Color(0xFF7AA67A);
  static const _orange = Color(0xFFBF7A5A);

  late final TabController _tabController;

  bool _isOnline = false;
  bool _isLoading = true;
  bool _isSaving = false;

  List<Shelter> _shelters = [];
  String? _lastUpdatedAt;
  LatLng? _frequentLocation;  // 常出現的位置（質心）
  LatLng? _currentLocation;   // 當前 GPS 位置
  String _locationLabel = '偵測位置中…';

  TileProvider? _tileProvider;
  final _mapController = MapController();
  bool _isLocating = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _init();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ── 初始化 ──────────────────────────────────────────────
  Future<void> _init() async {
    // 1. 網路狀態（加 timeout 避免卡住）
    bool online = false;
    try {
      final connectivity = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 5));
      online = connectivity.any((r) => r != ConnectivityResult.none);
    } catch (_) {}

    // 2. 地圖磚快取（失敗時降級為 NetworkTileProvider）
    try {
      final dir = await getApplicationCacheDirectory()
          .timeout(const Duration(seconds: 5));
      _tileProvider = CachedTileProvider(
        store: HiveCacheStore('${dir.path}/map_tiles'),
        maxStale: const Duration(days: 30),
      );
    } catch (_) {
      _tileProvider = NetworkTileProvider();
    }

    // 3. GPS 位置（最多等 8 秒，失敗也繼續）
    await _updateLocation();

    // 4. 載入避難所資料
    if (online) {
      await _loadOnlineData();
    } else {
      await _loadOfflineData();
    }

    // 5. 依距離排序
    _sortByDistance();

    if (mounted) {
      setState(() {
        _isOnline = online;
        _isLoading = false;
      });
    }
  }

  // ── GPS 位置 + 常出現位置計算 ────────────────────────────
  Future<void> _updateLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _locationLabel = '位置服務未開啟');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        setState(() => _locationLabel = '未取得位置權限');
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
      _currentLocation = LatLng(pos.latitude, pos.longitude);

      // 儲存到歷史記錄（最多保留 30 筆）
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKeyLocHistory);
      final List<Map<String, double>> history = raw != null
          ? (jsonDecode(raw) as List).map((e) => {'lat': (e['lat'] as num).toDouble(), 'lng': (e['lng'] as num).toDouble()}).toList()
          : [];

      history.add({'lat': pos.latitude, 'lng': pos.longitude});
      if (history.length > 30) history.removeAt(0);
      await prefs.setString(_prefsKeyLocHistory, jsonEncode(history));

      // 計算質心（常出現位置）
      final avgLat = history.map((e) => e['lat']!).reduce((a, b) => a + b) / history.length;
      final avgLng = history.map((e) => e['lng']!).reduce((a, b) => a + b) / history.length;
      _frequentLocation = LatLng(avgLat, avgLng);

      setState(() => _locationLabel = '常出現位置已更新（${history.length} 次記錄）');
    } on TimeoutException {
      setState(() => _locationLabel = '位置偵測逾時，使用預設資料');
    } catch (_) {
      setState(() => _locationLabel = '無法取得位置');
    }
  }

  // ── 依距離排序 ──────────────────────────────────────────
  void _sortByDistance() {
    final baseLocation = _frequentLocation ?? _currentLocation;
    if (baseLocation == null) return;

    for (final s in _shelters) {
      s.distanceKm = _calcDistKm(baseLocation.latitude, baseLocation.longitude, s.lat, s.lng);
    }
    _shelters.sort((a, b) => (a.distanceKm ?? 99).compareTo(b.distanceKm ?? 99));
  }

  // ── 線上載入資料 ─────────────────────────────────────────
  Future<void> _loadOnlineData() async {
    // TODO: 替換為 http.get(Uri.parse('https://your-api/shelters'))
    await Future.delayed(const Duration(milliseconds: 400));
    _shelters = _serverShelters.map((s) => Shelter.fromJson(s.toJson())).toList();
  }

  // ── 移動地圖到我的位置 ────────────────────────────────────
  Future<void> _locateMe() async {
    setState(() => _isLocating = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('請開啟位置權限以使用此功能')),
          );
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
      _currentLocation = LatLng(pos.latitude, pos.longitude);
      _mapController.move(_currentLocation!, 15.5);
      setState(() {});
    } on TimeoutException {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('位置偵測逾時，請稍後再試')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無法取得位置')));
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  // ── 離線載入快取 ─────────────────────────────────────────
  Future<void> _loadOfflineData() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyShelters);
    _lastUpdatedAt = prefs.getString(_prefsKeyUpdatedAt);

    if (raw != null) {
      final list = jsonDecode(raw) as List<dynamic>;
      _shelters = list.map((e) => Shelter.fromJson(e as Map<String, dynamic>)).toList();
    }
  }

  // ── 儲存離線地圖資料 ─────────────────────────────────────
  Future<void> _downloadOfflineMap() async {
    setState(() => _isSaving = true);
    await _loadOnlineData();
    _sortByDistance();

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final nowStr =
        '${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    await prefs.setString(_prefsKeyShelters, jsonEncode(_shelters.map((s) => s.toJson()).toList()));
    await prefs.setString(_prefsKeyUpdatedAt, nowStr);

    setState(() {
      _isSaving = false;
      _lastUpdatedAt = nowStr;
    });

    if (mounted) {
      // 切換到地圖頁，讓使用者瀏覽以快取地圖磚
      _tabController.animateTo(1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('避難所清單已儲存。請在地圖上瀏覽目標區域以快取地圖磚，離線時即可查看'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
          backgroundColor: const Color(0xFF5C3D2E),
        ),
      );
    }
  }

  // ── 開啟 GPS 導航 ────────────────────────────────────────
  Future<void> _openNavigation(Shelter shelter) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${shelter.lat},${shelter.lng}&travelmode=walking',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無法開啟地圖應用程式')),
        );
      }
    }
  }

  // ── 建構 UI ──────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('防空洞地圖'),
        iconTheme: const IconThemeData(color: _textPrimary),
        bottom: TabBar(
          controller: _tabController,
          labelColor: _textPrimary,
          unselectedLabelColor: _textSecondary,
          indicatorColor: _green,
          tabs: const [
            Tab(icon: Icon(Icons.list_rounded), text: '清單'),
            Tab(icon: Icon(Icons.map_rounded), text: '地圖'),
          ],
        ),
        actions: [
          if (_isOnline)
            _isSaving
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    icon: const Icon(Icons.download_rounded, color: _green),
                    tooltip: '儲存離線資料',
                    onPressed: _downloadOfflineMap,
                  ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _NetworkBanner(
                  isOnline: _isOnline,
                  lastUpdatedAt: _lastUpdatedAt,
                  locationLabel: _locationLabel,
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildListTab(),
                      _buildMapTab(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  // ── 清單頁 ───────────────────────────────────────────────
  Widget _buildListTab() {
    if (_shelters.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 52, color: _textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text('尚未下載離線資料', style: TextStyle(fontSize: 15, color: _textSecondary)),
            Text('請連上網路後點選右上角下載', style: TextStyle(fontSize: 13, color: _textSecondary.withValues(alpha: 0.7))),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _shelters.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final s = _shelters[index];
        final isNearest = index == 0 && s.distanceKm != null;
        final isFull = s.status == '即將滿員';
        final statusColor = isFull ? _orange : _green;

        return Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(18),
            border: isNearest ? Border.all(color: _green, width: 1.5) : null,
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
              // 最近避難所標籤
              if (isNearest)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: _green.withValues(alpha: 0.1),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.near_me_rounded, size: 13, color: _green),
                      SizedBox(width: 4),
                      Text('距你最近的避難所', style: TextStyle(fontSize: 12, color: _green, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // 編號
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _green.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _green),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.name,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _textPrimary)),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              Icon(Icons.people_outline_rounded, size: 13, color: _textSecondary),
                              const SizedBox(width: 3),
                              Text(s.capacity, style: TextStyle(fontSize: 12, color: _textSecondary)),
                              if (s.distanceKm != null) ...[
                                const SizedBox(width: 10),
                                Icon(Icons.directions_walk_rounded, size: 13, color: _textSecondary),
                                const SizedBox(width: 3),
                                Text(
                                  s.distanceKm! < 1
                                      ? '${(s.distanceKm! * 1000).round()} m'
                                      : '${s.distanceKm!.toStringAsFixed(1)} km',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isNearest ? _green : _textSecondary,
                                    fontWeight: isNearest ? FontWeight.w700 : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(s.status,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: statusColor)),
                        ),
                        const SizedBox(height: 8),
                        // 導航（有網路才啟用）
                        GestureDetector(
                          onTap: _isOnline ? () => _openNavigation(s) : null,
                          child: Row(
                            children: [
                              Icon(Icons.directions_rounded,
                                  size: 14,
                                  color: _isOnline ? _green : _textSecondary.withValues(alpha: 0.3)),
                              const SizedBox(width: 3),
                              Text('導航',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _isOnline ? _green : _textSecondary.withValues(alpha: 0.3),
                                    fontWeight: _isOnline ? FontWeight.w600 : FontWeight.normal,
                                  )),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── 地圖頁 ───────────────────────────────────────────────
  Widget _buildMapTab() {
    if (_tileProvider == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final center = _currentLocation ??
        _frequentLocation ??
        LatLng(_shelters.isNotEmpty ? _shelters[0].lat : 23.962,
               _shelters.isNotEmpty ? _shelters[0].lng : 120.969);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 14.5,
            maxZoom: 19,
            minZoom: 10,
          ),
          children: [
            // CartoDB Voyager：清晰、中英文標示、適合導航
            TileLayer(
              urlTemplate:
                  'https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.disaster_app',
              tileProvider: _tileProvider!,
              maxNativeZoom: 19,
            ),

            // 防空洞標記
            MarkerLayer(
              markers: [
                // 常出現位置（若與當前位置不同才顯示）
                if (_frequentLocation != null &&
                    (_currentLocation == null ||
                        _calcDistKm(
                              _frequentLocation!.latitude,
                              _frequentLocation!.longitude,
                              _currentLocation!.latitude,
                              _currentLocation!.longitude,
                            ) >
                            0.05))
                  Marker(
                    point: _frequentLocation!,
                    width: 44,
                    height: 44,
                    child: const _UserLocationMarker(label: '常出現位置'),
                  ),

                // 當前 GPS 位置（藍點）
                if (_currentLocation != null)
                  Marker(
                    point: _currentLocation!,
                    width: 56,
                    height: 56,
                    child: _CurrentPosMarker(),
                  ),

                // 避難所標記
                ..._shelters.asMap().entries.map((entry) {
                  final index = entry.key;
                  final s = entry.value;
                  return Marker(
                    point: LatLng(s.lat, s.lng),
                    width: 44,
                    height: 54,
                    child: GestureDetector(
                      onTap: () => _showShelterInfo(s, index),
                      child: _ShelterMarker(number: index + 1, isNearest: index == 0),
                    ),
                  );
                }),
              ],
            ),

            const SimpleAttributionWidget(
              source: Text('© CartoDB © OpenStreetMap', style: TextStyle(fontSize: 10)),
            ),
          ],
        ),

        // 我的位置按鈕
        Positioned(
          right: 16,
          bottom: 32,
          child: FloatingActionButton(
            heroTag: 'locateMe',
            mini: false,
            backgroundColor: Colors.white,
            elevation: 4,
            onPressed: _isLocating ? null : _locateMe,
            child: _isLocating
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF4A90D9)),
                  )
                : const Icon(Icons.my_location_rounded, color: Color(0xFF4A90D9), size: 26),
          ),
        ),
      ],
    );
  }

  // 點擊地圖標記顯示避難所資訊
  void _showShelterInfo(Shelter s, int index) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: _green.withValues(alpha: 0.1), shape: BoxShape.circle),
                  child: Center(
                    child: Text('${index + 1}',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _green)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.name,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _textPrimary)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(Icons.people_outline_rounded, '容納人數', s.capacity),
            _InfoRow(Icons.shield_rounded, '目前狀態', s.status,
                valueColor: s.status == '即將滿員' ? _orange : _green),
            if (s.distanceKm != null)
              _InfoRow(Icons.directions_walk_rounded, '距你距離',
                  s.distanceKm! < 1 ? '${(s.distanceKm! * 1000).round()} 公尺' : '${s.distanceKm!.toStringAsFixed(1)} 公里'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isOnline ? () { Navigator.pop(context); _openNavigation(s); } : null,
                icon: const Icon(Icons.directions_rounded),
                label: Text(_isOnline ? 'GPS 導航前往' : '無網路，無法導航'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _textSecondary.withValues(alpha: 0.2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 使用者常出現位置標記 ──────────────────────────────────
class _UserLocationMarker extends StatelessWidget {
  final String label;
  const _UserLocationMarker({required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFF4A90D9),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [BoxShadow(color: const Color(0xFF4A90D9).withValues(alpha: 0.4), blurRadius: 8)],
          ),
          child: const Icon(Icons.person_pin_rounded, color: Colors.white, size: 18),
        ),
      ],
    );
  }
}

// ── 當前 GPS 位置標記（綠點）────────────────────────────
class _CurrentPosMarker extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: const Color(0xFF4CAF50),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [BoxShadow(color: const Color(0xFF4CAF50).withValues(alpha: 0.5), blurRadius: 6)],
      ),
    );
  }
}

// ── 防空洞地圖標記 ───────────────────────────────────────
class _ShelterMarker extends StatelessWidget {
  final int number;
  final bool isNearest;

  const _ShelterMarker({required this.number, required this.isNearest});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF7AA67A);
    const orange = Color(0xFFBF7A5A);
    final color = isNearest ? orange : green;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: isNearest ? 40 : 34,
          height: isNearest ? 40 : 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 6)],
          ),
          child: Center(
            child: Text(
              '$number',
              style: TextStyle(
                color: Colors.white,
                fontSize: isNearest ? 16 : 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        CustomPaint(size: const Size(10, 6), painter: _PinTailPainter(color)),
      ],
    );
  }
}

class _PinTailPainter extends CustomPainter {
  final Color color;
  const _PinTailPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_) => false;
}

// ── 網路狀態橫幅 ─────────────────────────────────────────
class _NetworkBanner extends StatelessWidget {
  final bool isOnline;
  final String? lastUpdatedAt;
  final String locationLabel;

  const _NetworkBanner({required this.isOnline, this.lastUpdatedAt, required this.locationLabel});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF7AA67A);
    const orange = Color(0xFFBF7A5A);
    final color = isOnline ? green : orange;

    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                isOnline ? '已連線・顯示最新防空洞位置・可使用 GPS 導航' : '無網路・離線模式・無法使用導航',
                style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 13, color: Color(0xFF8C7B6E)),
              const SizedBox(width: 4),
              Text(locationLabel, style: const TextStyle(fontSize: 11, color: Color(0xFF8C7B6E))),
              if (!isOnline && lastUpdatedAt != null) ...[
                const SizedBox(width: 8),
                const Text('・', style: TextStyle(fontSize: 11, color: Color(0xFF8C7B6E))),
                const SizedBox(width: 4),
                Text('上次更新 $lastUpdatedAt', style: const TextStyle(fontSize: 11, color: Color(0xFF8C7B6E))),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ── 避難所資訊列 ─────────────────────────────────────────
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow(this.icon, this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    const textSecondary = Color(0xFF8C7B6E);
    const textPrimary = Color(0xFF3D2C1E);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: textSecondary),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13, color: textSecondary)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: valueColor ?? textPrimary)),
        ],
      ),
    );
  }
}
