"""firebase_rest：Firestore REST 的 Value 編碼與讀回。預期值照 Firestore REST 文件的格式手寫。"""

import unittest

import firebase_rest as fb


class TimestampTest(unittest.TestCase):
    def test_reads_what_firestore_returns_at_any_precision(self):
        self.assertEqual(1792627200000, fb.Timestamp.parse("2026-10-22T00:00:00Z").epoch_ms)
        self.assertEqual(1792627200120, fb.Timestamp.parse("2026-10-22T00:00:00.12Z").epoch_ms)
        self.assertEqual(1792627200123, fb.Timestamp.parse("2026-10-22T00:00:00.123456789Z").epoch_ms)

    def test_writes_milliseconds(self):
        self.assertEqual("2026-10-22T00:00:00.005Z", fb.Timestamp(1792627200005).rfc3339())

    def test_refuses_what_it_cannot_read(self):
        with self.assertRaises(ValueError):
            fb.Timestamp.parse("2026-10-22 00:00:00")


class ValueTest(unittest.TestCase):
    def test_arrays_and_maps(self):
        value = [{"uid": "uid-alice", "noticePublicKey": b"\x01\x02"}]
        encoded = {"arrayValue": {"values": [{"mapValue": {"fields": {
            "uid": {"stringValue": "uid-alice"},
            "noticePublicKey": {"bytesValue": "AQI="},
        }}}]}}

        self.assertEqual(encoded, fb.encode_value(value))
        self.assertEqual(value, fb.decode_value(encoded))

    def test_an_empty_array_comes_back_without_values(self):
        self.assertEqual([], fb.decode_value({"arrayValue": {}}))

    def test_scalars(self):
        for value in [None, True, 3, "文字", b"\x00", fb.Timestamp(1792627200000)]:
            with self.subTest(value):
                self.assertEqual(value, fb.decode_value(fb.encode_value(value)))
        self.assertEqual(3, fb.decode_value({"integerValue": "3"}))


if __name__ == "__main__":
    unittest.main()
