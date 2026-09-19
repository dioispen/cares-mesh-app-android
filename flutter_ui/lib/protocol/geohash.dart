/// 最小 geohash 解碼器 —— 把 base32 geohash 還原成所屬 cell 的中心座標。
///
/// 對應 `app/src/main/java/com/bitchat/android/geohash/Geohash.kt`。
/// Broadcast Tier 只需要解碼（把降精度 geohash 還原成近似座標）；編碼在 Kotlin 端做。
class Geohash {
  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  /// 回傳 (lat, lng) —— geohash cell 的中心座標。空字串或含非法字元時回傳 null。
  static (double, double)? decodeCenter(String geohash) {
    if (geohash.isEmpty) return null;

    var latMin = -90.0, latMax = 90.0;
    var lonMin = -180.0, lonMax = 180.0;
    var isEven = true;

    for (final ch in geohash.toLowerCase().codeUnits) {
      final cd = _base32.indexOf(String.fromCharCode(ch));
      if (cd < 0) return null;
      for (final mask in const [16, 8, 4, 2, 1]) {
        if (isEven) {
          final mid = (lonMin + lonMax) / 2;
          if ((cd & mask) != 0) {
            lonMin = mid;
          } else {
            lonMax = mid;
          }
        } else {
          final mid = (latMin + latMax) / 2;
          if ((cd & mask) != 0) {
            latMin = mid;
          } else {
            latMax = mid;
          }
        }
        isEven = !isEven;
      }
    }

    return ((latMin + latMax) / 2, (lonMin + lonMax) / 2);
  }
}
