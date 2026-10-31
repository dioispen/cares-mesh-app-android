import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/protocol/supply_exchange_packet.dart';

void main() {
  const vector = <int>[
    1,
    1,
    0,
    5,
    0x77,
    0x61,
    0x74,
    0x65,
    0x72,
    0,
    9,
    0xE7,
    0xA4,
    0xA6,
    0xE6,
    0xB3,
    0x89,
    0xE6,
    0xB0,
    0xB4,
    0,
    0,
    0,
    3,
    3,
    0xE7,
    0x93,
    0xB6,
  ];

  test('request encodes and decodes the Kotlin cross-platform vector', () {
    const packet = SupplyExchangePacket(
      action: 'request',
      itemId: 'water',
      itemName: '礦泉水',
      quantity: 3,
      unit: '瓶',
    );

    expect(packet.encode(), vector);
    expect(SupplyExchangePacket.decode(vector)?.action, 'request');
    expect(SupplyExchangePacket.decode(vector)?.itemName, '礦泉水');
    expect(SupplyExchangePacket.decode(vector)?.quantity, 3);
  });

  test('offer uses a distinct action code', () {
    final bytes = const SupplyExchangePacket(
      action: 'offer',
      itemId: 'blanket',
      itemName: '毛毯',
      quantity: 2,
      unit: '條',
    ).encode();

    expect(bytes[1], 2);
    expect(SupplyExchangePacket.decode(bytes)?.action, 'offer');
  });

  test(
    'rejects unknown versions, actions, zero quantity, and trailing data',
    () {
      expect(SupplyExchangePacket.decode([...vector]..[0] = 2), isNull);
      expect(SupplyExchangePacket.decode([...vector]..[1] = 3), isNull);
      expect(SupplyExchangePacket.decode([...vector]..[23] = 0), isNull);
      expect(SupplyExchangePacket.decode([...vector, 0]), isNull);
    },
  );

  test('encoder rejects invalid actions and quantities', () {
    expect(
      () => const SupplyExchangePacket(
        action: 'other',
        itemId: 'water',
        itemName: 'Water',
        quantity: 1,
        unit: 'bottle',
      ).encode(),
      throwsArgumentError,
    );
    expect(
      () => const SupplyExchangePacket(
        action: 'request',
        itemId: 'water',
        itemName: 'Water',
        quantity: 0,
        unit: 'bottle',
      ).encode(),
      throwsRangeError,
    );
  });
}
