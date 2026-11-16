import 'dart:convert';
import 'dart:typed_data';

/// SUPPLY_EXCHANGE（0x31）的 payload：一筆物資需求（request）或捐贈（offer），不含任何 PII。
///
/// 對應 `app/.../protocol/SupplyExchangePacket.kt` 的線路格式（big-endian）：
/// ```
///   [0]      version(1) = 1     其他版本一律拒收
///   [1]      action(1)          1=request / 2=offer
///   [2..17]  exchangeId(16)     這筆需求／捐贈的隨機 ID（UUID），與本人寫進
///                              supply_requests／supply_pledges 的文件 ID 相同
///   [..]     itemIdLen(2) + itemId(UTF-8)
///   [..]     itemNameLen(2) + itemName(UTF-8)
///   [..]     quantity(4)        unsigned，≥ 1
///   [..]     unitLen(1) + unit(UTF-8)
/// ```
/// 兩端共用同一組權威向量（`SupplyExchangePacketTest`、`supply_exchange_packet_test.dart`）。
class SupplyExchangePacket {
  static const int version = 1;
  static const int exchangeIdBytes = 16;
  static const int maxItemIdBytes = 64;
  static const int maxItemNameBytes = 96;
  static const int maxUnitBytes = 16;
  static const int maxQuantity = 0xffffffff;
  static const int maxEncodedSize =
      1 + 1 + exchangeIdBytes + 2 + maxItemIdBytes + 2 + maxItemNameBytes + 4 + 1 + maxUnitBytes;
  static const int _minEncodedSize = 1 + 1 + exchangeIdBytes + 2 + 1 + 2 + 1 + 4 + 1 + 1;

  static const int _request = 1;
  static const int _offer = 2;

  static final RegExp exchangeIdPattern = RegExp(r'^[0-9a-f]{32}$');

  /// 'request' 或 'offer'。
  final String action;

  /// 32 個小寫十六進位字元。
  final String exchangeId;
  final String itemId;
  final String itemName;
  final int quantity;
  final String unit;

  const SupplyExchangePacket({
    required this.action,
    required this.exchangeId,
    required this.itemId,
    required this.itemName,
    required this.quantity,
    required this.unit,
  });

  bool get isRequest => action == 'request';

  /// 由 UUID 字串（可含連字號、大小寫不拘）得到 32 碼小寫十六進位的 exchangeId。
  static String exchangeIdFromUuid(String uuid) => uuid.replaceAll('-', '').toLowerCase();

  Uint8List encode() {
    final actionByte = switch (action) {
      'request' => _request,
      'offer' => _offer,
      _ => throw ArgumentError.value(action, 'action', '只能是 request 或 offer'),
    };
    if (!exchangeIdPattern.hasMatch(exchangeId)) {
      throw ArgumentError.value(exchangeId, 'exchangeId', '必須是 32 個小寫十六進位字元');
    }
    final itemIdBytes = _encodeText(itemId, maxItemIdBytes, 'itemId');
    final itemNameBytes = _encodeText(itemName, maxItemNameBytes, 'itemName');
    final unitBytes = _encodeText(unit, maxUnitBytes, 'unit');
    if (quantity < 1 || quantity > maxQuantity) {
      throw RangeError.range(quantity, 1, maxQuantity, 'quantity');
    }

    final result = Uint8List(
      1 + 1 + exchangeIdBytes + 2 + itemIdBytes.length + 2 + itemNameBytes.length + 4 + 1 + unitBytes.length,
    );
    final data = ByteData.sublistView(result);
    var o = 0;
    data.setUint8(o++, version);
    data.setUint8(o++, actionByte);
    for (var i = 0; i < exchangeIdBytes; i++) {
      result[o++] = int.parse(exchangeId.substring(i * 2, i * 2 + 2), radix: 16);
    }
    data.setUint16(o, itemIdBytes.length, Endian.big);
    o += 2;
    result.setRange(o, o + itemIdBytes.length, itemIdBytes);
    o += itemIdBytes.length;
    data.setUint16(o, itemNameBytes.length, Endian.big);
    o += 2;
    result.setRange(o, o + itemNameBytes.length, itemNameBytes);
    o += itemNameBytes.length;
    data.setUint32(o, quantity, Endian.big);
    o += 4;
    data.setUint8(o++, unitBytes.length);
    result.setRange(o, o + unitBytes.length, unitBytes);
    return result;
  }

  /// 解碼失敗（未知版本、長度不符、字串非法、數量為 0、尾端多餘 bytes）回傳 null。
  static SupplyExchangePacket? decode(List<int> bytes) {
    try {
      final data = Uint8List.fromList(bytes);
      if (data.length < _minEncodedSize || data.length > maxEncodedSize) return null;
      final view = ByteData.sublistView(data);
      var o = 0;
      if (view.getUint8(o++) != version) return null;
      final action = switch (view.getUint8(o++)) {
        _request => 'request',
        _offer => 'offer',
        _ => null,
      };
      if (action == null) return null;
      final exchangeId = [
        for (var i = 0; i < exchangeIdBytes; i++) data[o + i].toRadixString(16).padLeft(2, '0'),
      ].join();
      o += exchangeIdBytes;

      final itemIdLen = view.getUint16(o, Endian.big);
      o += 2;
      if (itemIdLen < 1 || itemIdLen > maxItemIdBytes || data.length - o < itemIdLen) return null;
      final itemId = _decodeText(data, o, itemIdLen);
      if (itemId == null) return null;
      o += itemIdLen;

      final itemNameLen = view.getUint16(o, Endian.big);
      o += 2;
      if (itemNameLen < 1 || itemNameLen > maxItemNameBytes || data.length - o < itemNameLen) return null;
      final itemName = _decodeText(data, o, itemNameLen);
      if (itemName == null) return null;
      o += itemNameLen;

      if (data.length - o < 4 + 1) return null;
      final quantity = view.getUint32(o, Endian.big);
      o += 4;
      if (quantity == 0) return null;
      final unitLen = view.getUint8(o++);
      if (unitLen < 1 || unitLen > maxUnitBytes || data.length - o != unitLen) return null;
      final unit = _decodeText(data, o, unitLen);
      if (unit == null) return null;

      return SupplyExchangePacket(
        action: action,
        exchangeId: exchangeId,
        itemId: itemId,
        itemName: itemName,
        quantity: quantity,
        unit: unit,
      );
    } on RangeError {
      return null;
    }
  }

  static Uint8List _encodeText(String value, int maxBytes, String field) {
    final bytes = Uint8List.fromList(utf8.encode(value));
    if (value.trim().isEmpty || bytes.length > maxBytes) {
      throw ArgumentError.value(value, field, '必須非空白且不超過 $maxBytes 個 UTF-8 bytes');
    }
    return bytes;
  }

  static String? _decodeText(Uint8List bytes, int offset, int length) {
    try {
      final value = utf8.decode(bytes.sublist(offset, offset + length), allowMalformed: false);
      return value.trim().isEmpty ? null : value;
    } on FormatException {
      return null;
    }
  }
}
