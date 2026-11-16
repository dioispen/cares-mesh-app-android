import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bitchat_bridge.dart';
import '../protocol/ble_packet_decoder.dart';
import '../protocol/supply_exchange_packet.dart';

/// 附近裝置經 BLE mesh 送來的一筆物資需求／捐贈（Broadcast：不含姓名或帳號，只有 mesh peerID）。
class NearbySupplyExchange {
  const NearbySupplyExchange({
    required this.packet,
    required this.senderPeerId,
    required this.createdAt,
    required this.receivedAt,
  });

  final SupplyExchangePacket packet;

  /// 封包標頭的 senderID（16 個十六進位字元），只用來分辨是不是同一支手機。
  final String senderPeerId;

  /// 發送端建立這筆需求的時間（封包標頭 timestamp，對方手機的時鐘）。
  final DateTime createdAt;
  final DateTime receivedAt;

  String get exchangeId => packet.exchangeId;
  bool get isRequest => packet.isRequest;
}

/// 收集 mesh 上收到的物資封包，給物資頁的「附近」分頁顯示。整個 app 只有一個
/// [SupplyExchangeFeed.instance]，app 一啟動就 [start]（`main.dart`），物資頁沒開著也照收，
/// 和 [ChatService] 一樣。只放記憶體：Activity 重建會歸零，之後靠 gossip sync 補送回來。
///
/// 同一個 exchangeId 只留一筆（gossip 補送或多條路徑會重複收到）；超過 [retention] 的剔除；
/// 最多 [maxEntries] 筆，滿了剔除最舊的。
class SupplyExchangeFeed extends ChangeNotifier {
  /// 參數只給測試注入；正式環境用 [SupplyExchangeFeed.instance]。
  SupplyExchangeFeed({
    Stream<Map<String, dynamic>> Function()? events,
    DateTime Function()? now,
    this.retention = const Duration(hours: 2),
    this.maxEntries = 200,
  })  : _events = events ?? BitchatBridge.events,
        _now = now ?? DateTime.now;

  static final SupplyExchangeFeed instance = SupplyExchangeFeed();

  final Stream<Map<String, dynamic>> Function() _events;
  final DateTime Function() _now;
  final Duration retention;
  final int maxEntries;

  StreamSubscription<Map<String, dynamic>>? _subscription;
  final Map<String, NearbySupplyExchange> _byExchangeId = {};

  /// 最新收到的在前。
  List<NearbySupplyExchange> get entries {
    _forgetExpired();
    final list = _byExchangeId.values.toList()..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return List.unmodifiable(list);
  }

  List<NearbySupplyExchange> get requests => entries.where((e) => e.isRequest).toList();
  List<NearbySupplyExchange> get offers => entries.where((e) => !e.isRequest).toList();

  Future<void> start() async {
    if (_subscription != null) return;
    try {
      _subscription = _events().listen(_onEvent, onError: (Object e) {
        debugPrint('SupplyExchangeFeed: bridge events error: $e');
      });
    } catch (e) {
      // 沒有原生 bridge 的平台（iOS、測試）：沒有附近的封包可收。
      debugPrint('SupplyExchangeFeed: bridge events unavailable: $e');
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// 給測試與 [start] 用：處理一個 bridge 事件。
  @visibleForTesting
  void onEvent(Map<String, dynamic> event) => _onEvent(event);

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] != 'packet') return;
    if ((event['packetType'] as num?)?.toInt() != BlePacketType.supplyExchange) return;
    final ble = BlePacket.fromEvent(event);
    final packet = SupplyExchangePacket.decode(ble.payload);
    if (packet == null) return;
    final now = _now();
    final createdAt = ble.timestamp > 0 ? DateTime.fromMillisecondsSinceEpoch(ble.timestamp) : now;
    if (now.difference(createdAt) > retention) return;

    _byExchangeId[packet.exchangeId] = NearbySupplyExchange(
      packet: packet,
      senderPeerId: ble.senderId,
      createdAt: createdAt,
      receivedAt: now,
    );
    _forgetExpired();
    while (_byExchangeId.length > maxEntries) {
      final oldest = _byExchangeId.values.reduce((a, b) => a.receivedAt.isBefore(b.receivedAt) ? a : b);
      _byExchangeId.remove(oldest.exchangeId);
    }
    notifyListeners();
  }

  void _forgetExpired() {
    final cutoff = _now().subtract(retention);
    _byExchangeId.removeWhere((_, e) => e.createdAt.isBefore(cutoff));
  }
}
