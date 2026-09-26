import 'dart:async';
import 'package:flutter/services.dart';

/// 聊天 method 名稱，對應 Kotlin `ChatBridge` 的 companion 常數（命名規則 `chat_<動詞><受詞>`）。
abstract final class ChatMethods {
  static const sendMessage = 'chat_sendMessage';
  static const requestSnapshot = 'chat_requestSnapshot';
}

/// 聊天快照事件的 `type`，對應 Kotlin `ChatSerialization` 的常數（命名規則 `chat_<snake_case>`）。
abstract final class ChatEvents {
  /// `{type, messages: List<Map>}`：公開 mesh 時間線的完整快照，依時間線順序。
  static const publicMessages = 'chat_public_messages';
}

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

  /// 把使用者輸入的文字交給原生聊天核心（`ChatViewModel.sendMessage`）。
  ///
  /// 只收文字：送往哪裡（公開 mesh、目前開啟的私訊、`/` 指令）由原生核心依它自己的狀態決定，
  /// Dart 端沒有也不該有 peerId／isPublic 之類的參數（#9）。空白文字不會送出。
  /// 回傳原生核心是否接受；bridge 錯誤（例如 [PlatformException]）會往上拋。
  static Future<bool> sendMessage(String text) async {
    final bool? accepted = await _method.invokeMethod<bool>(
      ChatMethods.sendMessage,
      <String, dynamic>{'text': text},
    );
    return accepted ?? false;
  }

  /// 請原生端立刻重推所有 `chat_*` 快照事件（經事件串流送達，不是回傳值）。
  ///
  /// 事件串流是共用的 broadcast stream，原生端只在「第一個」Dart listener 訂閱時推快照；
  /// 較晚訂閱的 `ChatService` 用這個補拿目前狀態。
  static Future<void> requestChatSnapshot() async {
    await _method.invokeMethod<void>(ChatMethods.requestSnapshot);
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
