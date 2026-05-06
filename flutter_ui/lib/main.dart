import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:flutter/material.dart';
import 'bridge/bitchat_bridge.dart';
import 'screens/setup_screen.dart';

// 全局 NavigatorKey 用於在沒有 Context 的情況下顯示 Dialog
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async{
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // 優先檢查是否已有應用程式實例
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } else {
      // 如果已經存在，則直接使用目前的實例
      Firebase.app();
    }
  } catch (e) {
    // 捕獲所有初始化錯誤，避免引擎崩潰
    debugPrint('Firebase initialization warning: $e');
  }

  runApp(const BitchatFlutterUiApp());
}

class BitchatFlutterUiApp extends StatefulWidget {
  const BitchatFlutterUiApp({super.key});

  @override
  State<BitchatFlutterUiApp> createState() => _BitchatFlutterUiAppState();
}

class _BitchatFlutterUiAppState extends State<BitchatFlutterUiApp> {
  StreamSubscription? _statusSubscription;
  bool _isBluetoothDialogOpen = false;

  @override
  void initState() {
    super.initState();
    // 使用 addPostFrameCallback 確保 MaterialApp 已構建，Navigator 可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialStatus();
      _listenToSystemStatus();
    });
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }

  /// 主動檢查一次初始狀態，避免錯過 Stream 的第一次推送
  Future<void> _checkInitialStatus() async {
    try {
      // 擴展 Bridge 增加 getSystemStatus
      final status = await BitchatBridge.getSystemStatus();
      if (status != null) {
        _handleStatusUpdate(status);
      }
    } catch (e) {
      debugPrint('Error checking initial status: $e');
    }
  }

  void _listenToSystemStatus() {
    try {
      _statusSubscription = BitchatBridge.events().listen((event) {
        if (event['type'] == 'system_status') {
          _handleStatusUpdate(event);
        }
      });
    } catch (e) {
      debugPrint('Bridge events not available on this platform: $e');
    }
  }

  void _handleStatusUpdate(Map<String, dynamic> status) {
    bool bluetoothEnabled = status['bluetoothEnabled'] ?? true;

    if (!bluetoothEnabled) {
      _showBluetoothEnableDialog();
    } else {
      if (_isBluetoothDialogOpen) {
        navigatorKey.currentState?.pop();
        _isBluetoothDialogOpen = false;
      }
    }
  }

  void _showBluetoothEnableDialog() {
    if (_isBluetoothDialogOpen) return;

    final context = navigatorKey.currentContext;
    if (context == null) {
      // 如果 context 還是 null，延遲一下再試
      Future.delayed(const Duration(milliseconds: 500), _showBluetoothEnableDialog);
      return;
    }

    _isBluetoothDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.redAccent),
            SizedBox(width: 12),
            Text('藍牙已關閉'),
          ],
        ),
        content: const Text('Bitchat 需要藍牙功能才能建立 Mesh 網路並傳送訊息。請前往系統設定開啟藍牙。'),
      ),
    ).then((_) => _isBluetoothDialogOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Bitchat UI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5C3D2E)),
        useMaterial3: true,
      ),
      home: const SetupScreen(),
    );
  }
}
