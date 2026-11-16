import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/protocol/supply_exchange_packet.dart';

void main() {
  // 跨端權威向量 —— 與 app/.../protocol/SupplyExchangePacketTest.kt 的 vectorBytes 相同。
  // version=1, action=request(1), exchangeId=0123456789abcdef0123456789abcdef, itemId="water",
  // itemName="礦泉水", quantity=12, unit="瓶"。
  final vector = <int>[
    0x01, 0x01,
    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    0x00, 0x05, 0x77, 0x61, 0x74, 0x65, 0x72, // "water"
    0x00, 0x09, 0xE7, 0xA4, 0xA6, 0xE6, 0xB3, 0x89, 0xE6, 0xB0, 0xB4, // "礦泉水"
    0x00, 0x00, 0x00, 0x0C, // 12
    0x03, 0xE7, 0x93, 0xB6, // "瓶"
  ];
  const packet = SupplyExchangePacket(
    action: 'request',
    exchangeId: '0123456789abcdef0123456789abcdef',
    itemId: 'water',
    itemName: '礦泉水',
    quantity: 12,
    unit: '瓶',
  );

  test('encodes the authoritative vector byte for byte', () {
    expect(packet.encode(), vector);
    expect(vector.length, 44);
  });

  test('decodes the authoritative vector', () {
    final decoded = SupplyExchangePacket.decode(vector)!;
    expect(decoded.action, 'request');
    expect(decoded.isRequest, isTrue);
    expect(decoded.exchangeId, '0123456789abcdef0123456789abcdef');
    expect(decoded.itemId, 'water');
    expect(decoded.itemName, '礦泉水');
    expect(decoded.quantity, 12);
    expect(decoded.unit, '瓶');
  });

  test('an offer with the largest quantity round-trips', () {
    const offer = SupplyExchangePacket(
      action: 'offer',
      exchangeId: 'fedcba9876543210fedcba9876543210',
      itemId: 'battery',
      itemName: '電池（3號）',
      quantity: 0xffffffff,
      unit: '組',
    );
    final decoded = SupplyExchangePacket.decode(offer.encode())!;
    expect(decoded.action, 'offer');
    expect(decoded.quantity, 0xffffffff);
    expect(decoded.itemName, '電池（3號）');
  });

  test('exchangeId comes from the Firestore document UUID', () {
    expect(
      SupplyExchangePacket.exchangeIdFromUuid('0266794F-8EAB-4135-8076-B4EA1855E1F2'),
      '0266794f8eab41358076b4ea1855e1f2',
    );
  });

  test('rejects unknown version, unknown action, zero quantity, trailing bytes and truncation', () {
    expect(SupplyExchangePacket.decode([...vector]..[0] = 2), isNull);
    expect(SupplyExchangePacket.decode([...vector]..[1] = 3), isNull);
    final zeroQuantity = [...vector];
    zeroQuantity[37] = 0;
    zeroQuantity[38] = 0;
    zeroQuantity[39] = 0;
    expect(SupplyExchangePacket.decode(zeroQuantity), isNull);
    expect(SupplyExchangePacket.decode([...vector, 0x00]), isNull);
    expect(SupplyExchangePacket.decode(vector.sublist(0, vector.length - 1)), isNull);
    expect(SupplyExchangePacket.decode(const []), isNull);
  });

  test('rejects malformed UTF-8 and blank strings', () {
    expect(SupplyExchangePacket.decode([...vector]..[20] = 0xFF), isNull);
    final blank = [...vector];
    for (var i = 20; i < 25; i++) {
      blank[i] = 0x20;
    }
    expect(SupplyExchangePacket.decode(blank), isNull);
  });

  test('encoding refuses out-of-range fields', () {
    SupplyExchangePacket with_(
        {String? action, String? exchangeId, String? itemId, String? itemName, int? quantity, String? unit}) =>
        SupplyExchangePacket(
          action: action ?? packet.action,
          exchangeId: exchangeId ?? packet.exchangeId,
          itemId: itemId ?? packet.itemId,
          itemName: itemName ?? packet.itemName,
          quantity: quantity ?? packet.quantity,
          unit: unit ?? packet.unit,
        );
    expect(() => with_(quantity: 0).encode(), throwsRangeError);
    expect(() => with_(quantity: 0x100000000).encode(), throwsRangeError);
    expect(() => with_(action: 'cancel').encode(), throwsArgumentError);
    expect(() => with_(exchangeId: 'zz').encode(), throwsArgumentError);
    expect(() => with_(itemId: '').encode(), throwsArgumentError);
    expect(() => with_(itemName: 'x' * (SupplyExchangePacket.maxItemNameBytes + 1)).encode(), throwsArgumentError);
    expect(() => with_(unit: 'x' * (SupplyExchangePacket.maxUnitBytes + 1)).encode(), throwsArgumentError);
  });

  test('the largest legal packet fits maxEncodedSize', () {
    final largest = SupplyExchangePacket(
      action: 'request',
      exchangeId: packet.exchangeId,
      itemId: 'i' * SupplyExchangePacket.maxItemIdBytes,
      itemName: 'n' * SupplyExchangePacket.maxItemNameBytes,
      quantity: 1,
      unit: 'u' * SupplyExchangePacket.maxUnitBytes,
    );
    final bytes = largest.encode();
    expect(bytes.length, SupplyExchangePacket.maxEncodedSize);
    expect(SupplyExchangePacket.decode(bytes)!.itemName, largest.itemName);
  });
}
