import 'dart:async';
import 'package:flutter/services.dart';

class BitchatBridge {
  static const MethodChannel _method = MethodChannel('com.bitchat/bridge/methods');
  static const EventChannel _events = EventChannel('com.bitchat/bridge/events');

  // Cached broadcast stream — receiveBroadcastStream() must only be called once
  // per EventChannel; a second call creates a conflicting platform listener.
  static Stream<Map<String, dynamic>>? _cachedEventStream;

  static Stream<Map<String, dynamic>> events() {
    return _cachedEventStream ??= _events
        .receiveBroadcastStream()
        .map((dynamic e) {
          if (e is Map) {
            return e.map((k, v) => MapEntry(k.toString(), v));
          }
          return <String, dynamic>{'type': 'unknown', 'raw': e};
        })
        .asBroadcastStream();
  }

  /// 獲取當前系統狀態 (藍牙、位置、權限)
  static Future<Map<String, dynamic>?> getSystemStatus() async {
    try {
      final Map<dynamic, dynamic>? result = await _method.invokeMethod<Map>('getSystemStatus');
      return result?.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      return null;
    }
  }

  /// 檢查權限是否已開啟 (通知、藍牙、位置)
  static Future<bool> checkPermissions() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('checkPermissions');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 請求權限
  static Future<bool> requestPermissions() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('requestPermissions');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 檢查是否已註冊
  static Future<bool> isRegistered() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('isRegistered');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 執行註冊（產生原生密鑰並儲存暱稱）
  static Future<bool> register({required String nickname}) async {
    try {
      final bool? result = await _method.invokeMethod<bool>('register', {
        'nickname': nickname,
      });
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 獲取個人資料
  static Future<Map<String, dynamic>?> getProfile() async {
    try {
      final Map<dynamic, dynamic>? result = await _method.invokeMethod<Map>('getProfile');
      return result?.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      return null;
    }
  }

  /// 啟動 Mesh 服務
  static Future<bool> startMesh() async {
    try {
      final bool? result = await _method.invokeMethod<bool>('startMesh');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 發送訊息
  static Future<void> sendMessage({
    String? peerId,
    required String text,
    bool isPublic = true,
  }) async {
    await _method.invokeMethod<void>('sendMessage', <String, dynamic>{
      'peerId': peerId,
      'text': text,
      'isPublic': isPublic,
    });
  }

  /// 發送 Health Report 的 Broadcast Tier（BLE 廣播 + 網路回報）。
  ///
  /// 傳入的 map 只應含不具識別性的欄位：`reporterHandle`、`status`（中文 label）、
  /// 以及原始 `lat`/`lng`（由原生端就地降精度為 geohash）。姓名、電話、血型、自由文字
  /// 等 Detail Tier 欄位不要放進來——原生端也會忽略（見 ADR-0003）。
  static Future<void> sendHealthReport(Map<String, dynamic> broadcastTier) async {
    try {
      await _method.invokeMethod<void>('sendHealthReport', broadcastTier);
    } catch (e) {
      // Ignore
    }
  }

  /// 獲取附近裝置
  static Future<Map<String, String>> getNearbyPeers() async {
    try {
      final Map<dynamic, dynamic>? result = await _method.invokeMethod<Map>('getNearbyPeers');
      return result?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {};
    } catch (e) {
      return {};
    }
  }
}
