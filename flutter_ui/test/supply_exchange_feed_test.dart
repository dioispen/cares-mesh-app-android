import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/protocol/supply_exchange_packet.dart';
import 'package:flutter_ui/services/supply_exchange_feed.dart';

/// 附近裝置經 mesh 送來的物資封包，物資頁「附近」分頁的資料來源。
void main() {
  var now = DateTime(2026, 11, 16, 10, 0);
  late StreamController<Map<String, dynamic>> events;
  late SupplyExchangeFeed feed;

  Map<String, dynamic> packetEvent({
    String exchangeId = '0123456789abcdef0123456789abcdef',
    String action = 'request',
    int? timestamp,
    int packetType = 0x31,
    List<int>? payload,
  }) =>
      {
        'type': 'packet',
        'packetType': packetType,
        'senderId': '0102030405060708',
        'timestamp': timestamp ?? now.millisecondsSinceEpoch,
        'payload': payload ??
            SupplyExchangePacket(
              action: action,
              exchangeId: exchangeId,
              itemId: 'water',
              itemName: '礦泉水',
              quantity: 12,
              unit: '瓶',
            ).encode(),
      };

  setUp(() {
    events = StreamController<Map<String, dynamic>>.broadcast();
    feed = SupplyExchangeFeed(events: () => events.stream, now: () => now);
  });

  tearDown(() async {
    await feed.stop();
    await events.close();
  });

  test('a supply packet from the bridge shows up, newest first', () async {
    await feed.start();
    var notified = 0;
    feed.addListener(() => notified++);

    events.add(packetEvent());
    now = now.add(const Duration(minutes: 1));
    events.add(packetEvent(exchangeId: 'fedcba9876543210fedcba9876543210', action: 'offer'));
    await Future<void>.delayed(Duration.zero);

    expect(notified, 2);
    expect(feed.entries.map((e) => e.exchangeId), [
      'fedcba9876543210fedcba9876543210',
      '0123456789abcdef0123456789abcdef',
    ]);
    expect(feed.requests.single.packet.itemName, '礦泉水');
    expect(feed.offers.single.isRequest, isFalse);
  });

  test('the same exchangeId is kept once (gossip resends)', () {
    feed.onEvent(packetEvent());
    feed.onEvent(packetEvent());

    expect(feed.entries.length, 1);
  });

  test('other packet types, malformed payloads and expired packets are ignored', () {
    feed.onEvent(packetEvent(packetType: 0x30));
    feed.onEvent(packetEvent(payload: [0x01, 0x01, 0x00]));
    feed.onEvent(packetEvent(timestamp: now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch));
    feed.onEvent({'type': 'system_status', 'bluetoothEnabled': true});

    expect(feed.entries, isEmpty);
  });

  test('entries expire after the retention', () {
    feed.onEvent(packetEvent());
    expect(feed.entries.length, 1);

    now = now.add(const Duration(hours: 2, minutes: 1));

    expect(feed.entries, isEmpty);
  });

  test('the feed is capped and drops the oldest', () {
    final small = SupplyExchangeFeed(events: () => events.stream, now: () => now, maxEntries: 2);
    for (final id in ['a', 'b', 'c']) {
      small.onEvent(packetEvent(exchangeId: id * 32));
      now = now.add(const Duration(seconds: 1));
    }

    expect(small.entries.map((e) => e.exchangeId), ['c' * 32, 'b' * 32]);
  });
}
