import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user.dart';
import '../bridge/bitchat_bridge.dart';
import 'login_screen.dart';
import 'home_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> with WidgetsBindingObserver {
  String _statusText = '正在初始化...';
  bool _isChecking = false;
  bool _hasError = false;
  bool _needsPermissions = false;
  bool _meshStarted = false;
  Map<String, String> _nearbyPeers = {};
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startSetup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTasks();
    super.dispose();
  }

  void _stopTasks() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _isChecking = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasError) {
      _startSetup();
    }
  }

  Future<void> _startSetup() async {
    if (_isChecking) return;

    setState(() {
      _hasError = false;
      _needsPermissions = false;
      _meshStarted = false;
      _nearbyPeers = {};
      _isChecking = true;
      _statusText = '檢查必要權限與服務狀態...';
    });

    // Web 平台跳過原生藍牙步驟，直接驗證登入狀態
    if (kIsWeb) {
      setState(() => _statusText = '驗證身分中...');
      _checkRegistration();
      return;
    }

    // 1. 檢查權限
    bool hasPermissions = await BitchatBridge.checkPermissions();
    if (!hasPermissions) {
      setState(() {
        _hasError = true;
        _needsPermissions = true;
        _isChecking = false;
        _statusText = '藍牙與位置權限未開啟。\n請授權後點擊「授權權限」繼續。';
      });
      await BitchatBridge.requestPermissions();
      return;
    }

    // 2. 啟動 Mesh 服務
    setState(() => _statusText = '啟動藍牙掃描與 Mesh 服務...');
    bool started = await BitchatBridge.startMesh();
    if (!started) {
      setState(() {
        _hasError = true;
        _isChecking = false;
        _statusText = '啟動 Mesh 失敗。\n請確認藍牙已開啟，且通知權限已允許。';
      });
      return;
    }

    setState(() {
      _meshStarted = true;
      _statusText = '正在搜尋附近 Bitchat 節點...';
    });

    // 3. 開始搜尋附近裝置並進行註冊檢查
    _searchTimer?.cancel();
    _searchTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final peers = await BitchatBridge.getNearbyPeers();
      if (mounted) {
        setState(() => _nearbyPeers = peers);
      }

      // 搜尋滿一次 tick 後即可進行身份驗證
      if (timer.tick >= 1) {
        _checkRegistration();
      }
    });
  }

  Future<void> _checkRegistration() async {
    if (!mounted) return;

    _stopTasks();

    setState(() {
      _isChecking = true;
      _statusText = '驗證身分中...';
    });

    bool isRegisteredInCloud = false;
    bool hasLocalData = false;

    try {
      bool nativeRegistered = await BitchatBridge.isRegistered();
      final firebaseUser = FirebaseAuth.instance.currentUser;
      debugPrint('DEBUG: Native: $nativeRegistered, FirebaseUser: ${firebaseUser?.uid}');

      if (nativeRegistered || firebaseUser != null) {
        final prefs = await SharedPreferences.getInstance();
        final userJson = prefs.getString('app_user');

        if (userJson != null) {
          hasLocalData = true;
          final user = AppUser.fromJson(jsonDecode(userJson));
          debugPrint('DEBUG: Local user found: ${user.id}');

          final cloudDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.id)
              .get()
              .timeout(const Duration(seconds: 5));

          if (cloudDoc.exists) {
            isRegisteredInCloud = true;
            debugPrint('DEBUG: Cloud registration verified.');
          }
        } else if (firebaseUser != null) {
          debugPrint('DEBUG: No local data, trying to restore from Firestore...');
          final cloudDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(firebaseUser.uid)
              .get()
              .timeout(const Duration(seconds: 5));

          if (cloudDoc.exists && cloudDoc.data() != null) {
            final appUser = AppUser.fromJson(cloudDoc.data()!);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('app_user', jsonEncode(appUser.toJson()));
            isRegisteredInCloud = true;
            debugPrint('DEBUG: Restored user data from Firestore.');
          }
        }
      }
    } catch (e) {
      debugPrint('DEBUG: Registration check failed or timed out: $e');
      if (hasLocalData) {
        debugPrint('DEBUG: Proceeding in offline mode with local data.');
        isRegisteredInCloud = true;
      }
    }

    if (!mounted) return;

    setState(() => _isChecking = false);

    if (isRegisteredInCloud) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const brown = Color(0xFF5C3D2E);
    const bg = Color(0xFFF7F3EC);

    final bool showSpinner = _isChecking && !_hasError;

    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _hasError
                    ? Icons.error_outline_rounded
                    : (_meshStarted
                        ? Icons.bluetooth_searching_rounded
                        : Icons.bluetooth_rounded),
                size: 80,
                color: _hasError ? Colors.redAccent : brown,
              ),
              const SizedBox(height: 32),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _hasError ? Colors.redAccent : brown,
                ),
              ),
              const SizedBox(height: 24),
              if (showSpinner) ...[
                const CircularProgressIndicator(color: brown),
                const SizedBox(height: 32),
                if (_nearbyPeers.isNotEmpty) ...[
                  const Text(
                    '附近已發現裝置：',
                    style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _nearbyPeers.length,
                      itemBuilder: (context, index) {
                        final entry = _nearbyPeers.entries.elementAt(index);
                        return ListTile(
                          leading: const Icon(Icons.devices, color: brown),
                          title: Text(entry.value),
                          subtitle: Text('ID: ${entry.key.substring(0, 8)}'),
                        );
                      },
                    ),
                  ),
                ] else ...[
                  const Text(
                    '正在尋找其他 Bitchat 節點...',
                    style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
                  ),
                ],
              ],
              const SizedBox(height: 32),
              // 手動檢查按鈕：不管狀態如何都顯示（非 checking 狀態下可點）
              ElevatedButton.icon(
                onPressed: _isChecking
                    ? null
                    : () {
                        if (_needsPermissions) {
                          BitchatBridge.requestPermissions();
                        } else {
                          _startSetup();
                        }
                      },
                icon: Icon(_needsPermissions ? Icons.lock_open_rounded : Icons.refresh_rounded),
                label: Text(
                  _isChecking
                      ? '檢查中...'
                      : (_needsPermissions ? '授權權限' : '重新檢查並啟動'),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: brown,
                  foregroundColor: bg,
                  disabledBackgroundColor: brown.withValues(alpha: 0.4),
                  disabledForegroundColor: bg,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
