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
    String senderId = '0102030405060708',
    int quantity = 12,
    int? timestamp,
    int packetType = 0x32,
    List<int>? payload,
  }) =>
      {
        'type': 'packet',
        'packetType': packetType,
        'senderId': senderId,
        'timestamp': timestamp ?? now.millisecondsSinceEpoch,
        'payload': payload ??
            SupplyExchangePacket(
              action: action,
              exchangeId: exchangeId,
              itemId: 'water',
              itemName: '礦泉水',
              quantity: quantity,
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

  test('another peer reusing an exchangeId does not replace the original entry', () {
    feed.onEvent(packetEvent());
    feed.onEvent(packetEvent(senderId: '1111111111111111', quantity: 999));

    final original = feed.entries.singleWhere((e) => e.senderPeerId == '0102030405060708');
    expect(original.packet.quantity, 12);
    expect(feed.entries.length, 2);
  });

  test('packets dated past the clock-skew tolerance are ignored', () {
    feed.onEvent(packetEvent(
      exchangeId: 'a' * 32,
      timestamp: now.add(const Duration(minutes: 10, seconds: 1)).millisecondsSinceEpoch,
    ));
    feed.onEvent(packetEvent(
      exchangeId: 'b' * 32,
      timestamp: now.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    ));

    expect(feed.entries.map((e) => e.exchangeId), ['b' * 32]);
  });

  test('newer packets win even when they arrive at the same receive time', () {
    final sameReceiveAt = DateTime(2026, 11, 16, 10, 1);
    final tieFeed = SupplyExchangeFeed(
      events: () => events.stream,
      now: () => sameReceiveAt,
    );

    tieFeed.onEvent(packetEvent(timestamp: DateTime(2026, 11, 16, 10, 0).millisecondsSinceEpoch));
    tieFeed.onEvent(
      packetEvent(
        exchangeId: 'fedcba9876543210fedcba9876543210',
        action: 'offer',
        timestamp: DateTime(2026, 11, 16, 10, 1).millisecondsSinceEpoch,
      ),
    );

    expect(tieFeed.entries.map((e) => e.exchangeId), [
      'fedcba9876543210fedcba9876543210',
      '0123456789abcdef0123456789abcdef',
    ]);
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
