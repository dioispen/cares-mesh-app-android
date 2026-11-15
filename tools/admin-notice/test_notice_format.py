"""notice_format：Admin Notice payload 的組包、簽章與檢查。

預期值取自 docs/ADMIN_NOTICE_V1.md 附錄的 test vectors 與「參數」一節，不由程式重算。
"""

import hashlib
import unittest

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import notice_format as nf

# 附錄「共用金鑰」：admin Ed25519 seed 與公鑰（只能用於測試）
TEST_ADMIN = Ed25519PrivateKey.from_private_bytes(
    hashlib.sha256(b"cares-admin-notice-test/admin").digest())
TEST_ADMIN_PUBLIC = bytes.fromhex("10f835a2f82b877a2c1c705ef3c71d3640a40b4e39f6ca4197c17eaefb05a176")

ISSUED_AT = 1792627200000  # 附錄的 issuedAt：2026-10-22T00:00:00Z
HOUR = 3_600_000
V1_MESSAGE_ID = bytes.fromhex("a1b2c3d4e5f60718")
V1_CONTENT = "土石流警戒：請立即撤離至大同國小避難所"
V1_PAYLOAD = bytes.fromhex(
    "01010103a1b2c3d4e5f60718000001a160e85000000001a16231e70000000000"
    "00000000e59c9fe79fb3e6b581e8ada6e68892efbc9ae8ab8be7ab8be58db3e6"
    "92a4e99ba2e887b3e5a4a7e5908ce59c8be5b08fe981bfe99ba3e689805c770d"
    "5b6d3a8d4165dd74006650f7c96b1fab54ec1340438ad884db367d8a7f2d0288"
    "9bc878922000ad2616d9dbaa019eeaeeecc4af17d7813bb76eb8a5a60b")
V3_PAYLOAD = bytes.fromhex(
    "010101035566778899aabbcc000001a160f177c0000001a16231e700a1b2c3d4"
    "e5f60718906c626ca840e351bfaa44b6778bc7ca50e99aa5470cb920602c403d"
    "45763debcff0ff88c8cd9d7db40447416a64671333382ec93cd5f3fda36fcbe1"
    "f5b54301")


def broadcast(**overrides) -> bytes:
    """以附錄 V1 的輸入組一則廣播，個別欄位可以覆寫。"""
    fields = dict(key_id=0x01, level=nf.LEVEL_URGENT, message_id=V1_MESSAGE_ID,
                  issued_at=ISSUED_AT, expires_at=ISSUED_AT + 6 * HOUR, content=V1_CONTENT)
    fields.update(overrides)
    return nf.build_broadcast(TEST_ADMIN, **fields)


class BuildBroadcastTest(unittest.TestCase):
    def test_v1_is_byte_identical_to_the_spec_appendix(self):
        self.assertEqual(V1_PAYLOAD, broadcast())

    def test_v3_pure_withdrawal_is_byte_identical_to_the_spec_appendix(self):
        payload = broadcast(message_id=bytes.fromhex("5566778899aabbcc"),
                            issued_at=ISSUED_AT + 600_000, content="", replaces=V1_MESSAGE_ID)
        self.assertEqual(V3_PAYLOAD, payload)

    def test_signature_verifies_with_the_admin_public_key(self):
        nf.verify(TEST_ADMIN_PUBLIC, broadcast())

    def test_tampered_payload_does_not_verify(self):
        tampered = bytearray(broadcast())
        tampered[3] = nf.LEVEL_INFO
        with self.assertRaises(InvalidSignature):
            nf.verify(TEST_ADMIN_PUBLIC, bytes(tampered))


class BroadcastLimitsTest(unittest.TestCase):
    """docs/ADMIN_NOTICE_V1.md「廣播 body」「處理規則」第 1、2、5、6 步：App 會丟掉的公告不能簽出去。"""

    def assert_rejected(self, **overrides):
        with self.assertRaises(nf.NoticeError):
            broadcast(**overrides)

    def test_content_up_to_300_utf8_bytes_is_accepted(self):
        self.assertEqual(400, len(broadcast(content="a" * 300)))  # 附錄「大小上限」：300 bytes → 400
        broadcast(content="警" * 100)  # 100 個中文字 = 300 bytes

    def test_content_over_300_utf8_bytes_is_rejected(self):
        self.assert_rejected(content="a" * 301)
        self.assert_rejected(content="警" * 101)  # 101 個字，但 303 bytes

    def test_empty_content_is_rejected_unless_it_withdraws_another_notice(self):
        self.assert_rejected(content="")

    def test_validity_up_to_24_hours_is_accepted(self):
        broadcast(expires_at=ISSUED_AT + 24 * HOUR)

    def test_validity_over_24_hours_is_rejected(self):
        self.assert_rejected(expires_at=ISSUED_AT + 24 * HOUR + 1)

    def test_expiry_not_after_issue_time_is_rejected(self):
        self.assert_rejected(expires_at=ISSUED_AT)
        self.assert_rejected(expires_at=ISSUED_AT - 1)

    def test_all_zero_message_id_is_rejected(self):
        self.assert_rejected(message_id=bytes(8))

    def test_message_id_must_be_8_bytes(self):
        self.assert_rejected(message_id=bytes.fromhex("a1b2c3d4e5f607"))
        self.assert_rejected(message_id=bytes.fromhex("a1b2c3d4e5f6071800"))

    def test_notice_cannot_replace_itself(self):
        self.assert_rejected(replaces=V1_MESSAGE_ID)

    def test_unknown_level_is_rejected(self):
        self.assert_rejected(level=0x00)
        self.assert_rejected(level=0x04)

    def test_reserved_key_id_zero_is_rejected(self):
        self.assert_rejected(key_id=0x00)


class NewMessageIdTest(unittest.TestCase):
    def test_is_8_random_bytes(self):
        self.assertEqual(8, len(nf.new_message_id()))
        self.assertNotEqual(nf.new_message_id(), nf.new_message_id())

    def test_draws_again_when_the_random_source_returns_all_zeros(self):
        draws = iter([bytes(8), bytes.fromhex("0000000000000001")])
        self.assertEqual(bytes.fromhex("0000000000000001"), nf.new_message_id(lambda n: next(draws)))


if __name__ == "__main__":
    unittest.main()
