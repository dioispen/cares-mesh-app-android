import 'dart:convert';
import 'dart:typed_data';

/// Versioned wire payload for mesh supply requests and offers.
class SupplyExchangePacket {
  static const int version = 1;
  static const int _request = 1;
  static const int _offer = 2;
  static const int maxItemIdBytes = 128;
  static const int maxItemNameBytes = 256;
  static const int maxUnitBytes = 64;
  static const int maxQuantity = 0xffffffff;

  final String action;
  final String itemId;
  final String itemName;
  final int quantity;
  final String unit;

  const SupplyExchangePacket({
    required this.action,
    required this.itemId,
    required this.itemName,
    required this.quantity,
    required this.unit,
  });

  Uint8List encode() {
    final actionByte = switch (action) {
      'request' => _request,
      'offer' => _offer,
      _ => throw ArgumentError.value(
        action,
        'action',
        'Must be request or offer',
      ),
    };
    final itemIdBytes = _encodeText(itemId, maxItemIdBytes, 'itemId');
    final itemNameBytes = _encodeText(itemName, maxItemNameBytes, 'itemName');
    final unitBytes = _encodeText(unit, maxUnitBytes, 'unit');
    if (quantity < 1 || quantity > maxQuantity) {
      throw RangeError.range(quantity, 1, maxQuantity, 'quantity');
    }

    final result = Uint8List(
      1 +
          1 +
          2 +
          itemIdBytes.length +
          2 +
          itemNameBytes.length +
          4 +
          1 +
          unitBytes.length,
    );
    final data = ByteData.sublistView(result);
    var offset = 0;
    data.setUint8(offset++, version);
    data.setUint8(offset++, actionByte);
    data.setUint16(offset, itemIdBytes.length, Endian.big);
    offset += 2;
    result.setRange(offset, offset + itemIdBytes.length, itemIdBytes);
    offset += itemIdBytes.length;
    data.setUint16(offset, itemNameBytes.length, Endian.big);
    offset += 2;
    result.setRange(offset, offset + itemNameBytes.length, itemNameBytes);
    offset += itemNameBytes.length;
    data.setUint32(offset, quantity, Endian.big);
    offset += 4;
    data.setUint8(offset++, unitBytes.length);
    result.setRange(offset, offset + unitBytes.length, unitBytes);
    return result;
  }

  static SupplyExchangePacket? decode(List<int> bytes) {
    try {
      final data = Uint8List.fromList(bytes);
      if (data.length < 14) return null;
      final view = ByteData.sublistView(data);
      var offset = 0;
      if (view.getUint8(offset++) != version) return null;
      final action = switch (view.getUint8(offset++)) {
        _request => 'request',
        _offer => 'offer',
        _ => null,
      };
      if (action == null) return null;
      final itemId = _readText(data, view, maxItemIdBytes, offset);
      if (itemId == null) return null;
      offset += 2 + utf8.encode(itemId).length;
      final itemName = _readText(data, view, maxItemNameBytes, offset);
      if (itemName == null) return null;
      offset += 2 + utf8.encode(itemName).length;
      if (data.length - offset < 5) return null;
      final quantity = view.getUint32(offset, Endian.big);
      offset += 4;
      if (quantity == 0) return null;
      final unitLength = view.getUint8(offset++);
      if (unitLength == 0 ||
          unitLength > maxUnitBytes ||
          data.length - offset != unitLength) {
        return null;
      }
      final unit = _decodeText(data, offset, unitLength);
      if (unit == null || unit.trim().isEmpty) return null;
      return SupplyExchangePacket(
        action: action,
        itemId: itemId,
        itemName: itemName,
        quantity: quantity,
        unit: unit,
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  static Uint8List _encodeText(String value, int maxBytes, String field) {
    final bytes = Uint8List.fromList(utf8.encode(value));
    if (value.trim().isEmpty || bytes.length > maxBytes) {
      throw ArgumentError.value(
        value,
        field,
        'Must be non-empty and at most $maxBytes UTF-8 bytes',
      );
    }
    return bytes;
  }

  static String? _readText(
    Uint8List bytes,
    ByteData view,
    int maxBytes,
    int offset,
  ) {
    if (bytes.length - offset < 2) return null;
    final length = view.getUint16(offset, Endian.big);
    if (length == 0 || length > maxBytes || bytes.length - offset - 2 < length) {
      return null;
    }
    final value = _decodeText(bytes, offset + 2, length);
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  static String? _decodeText(Uint8List bytes, int offset, int length) => utf8
      .decode(bytes.sublist(offset, offset + length), allowMalformed: false);
}
