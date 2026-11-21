"""notice_format：Admin Notice payload 的組包、簽章與檢查。

預期值取自 docs/ADMIN_NOTICE_V1.md 附錄的 test vectors 與「參數」一節，不由程式重算。
"""

import hashlib
import unittest

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey

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


def x25519(label: str) -> X25519PrivateKey:
    return X25519PrivateKey.from_private_bytes(hashlib.sha256(label.encode()).digest())


# 附錄「共用金鑰」的收件者私鑰
RECIPIENT_1 = x25519("cares-admin-notice-test/recipient-1")
RECIPIENT_2 = x25519("cares-admin-notice-test/recipient-2")
OUTSIDER = x25519("cares-admin-notice-test/outsider")
V2_CONTENT = "救援人員約 10 分鐘內抵達，請留在原地"


def targeted(recipients, **overrides) -> bytes:
    fields = dict(key_id=0x01, level=nf.LEVEL_IMPORTANT, message_id=bytes.fromhex("0f1e2d3c4b5a6978"),
                  issued_at=ISSUED_AT, expires_at=ISSUED_AT + 2 * HOUR, content=V2_CONTENT)
    fields.update(overrides)
    return nf.build_targeted(TEST_ADMIN, recipients=[nf.raw_public(r) for r in recipients], **fields)


class BuildTargetedTest(unittest.TestCase):
    """docs/ADMIN_NOTICE_V1.md「定向 body」：發送工具每次都用新的亂數金鑰，所以不比對附錄的位元組。"""

    def test_every_recipient_opens_it_and_the_outsider_does_not(self):
        payload = targeted([RECIPIENT_1, RECIPIENT_2])

        nf.verify(TEST_ADMIN_PUBLIC, payload)
        self.assertEqual(bytes([nf.VERSION, nf.KIND_TARGETED, 0x01, nf.LEVEL_IMPORTANT]), payload[:4])
        self.assertEqual(2, payload[nf.HEADER_SIZE + 32])  # recipientCount
        self.assertEqual(V2_CONTENT.encode(), nf.open_as_recipient(payload, RECIPIENT_1))
        self.assertEqual(V2_CONTENT.encode(), nf.open_as_recipient(payload, RECIPIENT_2))
        self.assertIsNone(nf.open_as_recipient(payload, OUTSIDER))

    def test_payload_size_matches_the_size_table(self):
        # 「大小上限」：5 個收件裝置、內容 300 bytes → payload 661
        five = [x25519(f"recipient-{i}") for i in range(5)]
        self.assertEqual(661, len(targeted(five, content="a" * 300)))

    def test_keys_are_fresh_for_every_notice(self):
        first, second = targeted([RECIPIENT_1]), targeted([RECIPIENT_1])
        self.assertNotEqual(first[nf.HEADER_SIZE:nf.HEADER_SIZE + 32], second[nf.HEADER_SIZE:nf.HEADER_SIZE + 32])
        self.assertNotEqual(first[:-nf.SIGNATURE_SIZE], second[:-nf.SIGNATURE_SIZE])

    def test_recipient_entries_are_in_random_order(self):
        recipients = [x25519(f"recipient-{i}") for i in range(5)]
        positions = set()
        for _ in range(20):
            payload = targeted(recipients)
            positions.add(entry_position(payload, recipients[0]))
        # 20 次都排在同一個位置的機率是 5^-19
        self.assertGreater(len(positions), 1)

    def test_one_to_five_recipients(self):
        targeted([RECIPIENT_1])
        targeted([x25519(f"recipient-{i}") for i in range(5)])
        with self.assertRaises(nf.NoticeError):
            targeted([])
        with self.assertRaises(nf.NoticeError):
            targeted([x25519(f"recipient-{i}") for i in range(6)])

    def test_the_same_recipient_twice_is_rejected(self):
        with self.assertRaises(nf.NoticeError):
            targeted([RECIPIENT_1, RECIPIENT_1])

    def test_empty_content_is_rejected(self):
        # 純撤回一律用廣播 kind（「撤回與取代」），定向公告一定有內容。
        with self.assertRaises(nf.NoticeError):
            targeted([RECIPIENT_1], content="")

    def test_content_over_300_bytes_is_rejected(self):
        with self.assertRaises(nf.NoticeError):
            targeted([RECIPIENT_1], content="警" * 101)

    def test_a_public_key_that_is_not_32_bytes_is_rejected(self):
        with self.assertRaises(nf.NoticeError):
            nf.build_targeted(TEST_ADMIN, key_id=0x01, level=nf.LEVEL_INFO, message_id=V1_MESSAGE_ID,
                              issued_at=ISSUED_AT, expires_at=ISSUED_AT + HOUR, content="x",
                              recipients=[bytes(31)])

    def test_a_small_order_public_key_is_rejected(self):
        # X25519 結果全為 0 時中止（「定向 body」管理端加密第 2 步）
        with self.assertRaises(nf.NoticeError):
            nf.build_targeted(TEST_ADMIN, key_id=0x01, level=nf.LEVEL_INFO, message_id=V1_MESSAGE_ID,
                              issued_at=ISSUED_AT, expires_at=ISSUED_AT + HOUR, content="x",
                              recipients=[bytes(32)])

    def test_header_limits_apply_as_for_a_broadcast(self):
        with self.assertRaises(nf.NoticeError):
            targeted([RECIPIENT_1], expires_at=ISSUED_AT + 24 * HOUR + 1)


def entry_position(payload: bytes, recipient: X25519PrivateKey) -> int:
    """recipient 的條目排在第幾個（收件端以 tag 認出自己的條目）。"""
    message_id, body = payload[4:12], payload[nf.HEADER_SIZE:-nf.SIGNATURE_SIZE]
    eph_pub, count = body[:32], body[32]
    shared = recipient.exchange(X25519PublicKey.from_public_bytes(eph_pub))
    tag, _ = nf.recipient_secrets(shared, message_id, eph_pub, nf.raw_public(recipient))
    tags = [body[33 + 40 * i:41 + 40 * i] for i in range(count)]
    return tags.index(tag)


class NewMessageIdTest(unittest.TestCase):
    def test_is_8_random_bytes(self):
        self.assertEqual(8, len(nf.new_message_id()))
        self.assertNotEqual(nf.new_message_id(), nf.new_message_id())

    def test_draws_again_when_the_random_source_returns_all_zeros(self):
        draws = iter([bytes(8), bytes.fromhex("0000000000000001")])
        self.assertEqual(bytes.fromhex("0000000000000001"), nf.new_message_id(lambda n: next(draws)))


if __name__ == "__main__":
    unittest.main()
