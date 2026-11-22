"""send --replaces 與 revoke 對著 Firebase emulator 跑（#139）：讀 admin_notice_records 的
batchGet、runQuery 與寫入都真的經過 firestore.rules。

只有設定 FIRESTORE_EMULATOR_HOST 與 FIREBASE_AUTH_EMULATOR_HOST 時才執行，平常略過。
執行方式見 README.md「測試」。不會連到任何線上專案。
"""

import base64
import os
import re
import time
import unittest

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import admin_notice_tool as tool
import firebase_rest as fb
import notice_format as nf
from test_emulator_send import (
    PASSWORD, PROJECT, TEST_PUBLIC_HEX, EmulatorTestCase, documents_url, read_as_owner, request,
)

CONTENT = "土石流警戒：請立即撤離至大同國小避難所"


class ReplaceAndRevokeThroughEmulatorTest(EmulatorTestCase):
    def run_tool(self, *argv) -> int:
        self.stdout.seek(0)
        self.stdout.truncate()
        self.stderr.seek(0)
        self.stderr.truncate()
        return tool.main(
            [*argv, "--email", "admin@example.org", "--key", str(self.key_path), "--yes"],
            tool.Deps(stdout=self.stdout, stderr=self.stderr,
                      env={**os.environ, tool.PASSWORD_ENV: PASSWORD},
                      public_keys_path=self.public_keys, google_services_path=self.google_services))

    def send(self, *extra, valid_for="6h", content=CONTENT) -> int:
        return self.run_tool("send", "--level", "urgent", "--content", content, "--valid-for", valid_for, *extra)

    def written(self) -> list:
        """這次寫入的每一則：(messageId, wire, admin_notice_records 的欄位)。"""
        notices = []
        for message_id in re.findall(r"已寫入 admin_notices/([0-9a-f]{16})", self.stdout.getvalue()):
            wire = base64.b64decode(read_as_owner(f"admin_notices/{message_id}")["fields"]["wire"]["bytesValue"])
            nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), wire)
            record = read_as_owner(f"admin_notice_records/{message_id}")["fields"]
            notices.append((message_id, wire, {k: fb.decode_value(v) for k, v in record.items()}))
        return notices

    def notice_count(self) -> int:
        return len(request("GET", documents_url("/admin_notices"), token="owner").get("documents", []))

    def register(self, uid: str, handle: str) -> X25519PrivateKey:
        """以 owner 登記一台裝置（rules 由 test_emulator_send 測過）。"""
        key = X25519PrivateKey.generate()
        fields = {"reporterHandle": handle, "signingPublicKey": bytes(32), "noticePublicKey": nf.raw_public(key),
                  "registeredAt": fb.Timestamp(int(time.time() * 1000))}
        fb.commit(fb.urllib_post, fb.Endpoints.from_env(os.environ), PROJECT, "owner",
                  [fb.create_write(PROJECT, f"reporter_handles/{uid}/installations/{handle}", fields)])
        return key

    def test_a_correction_expiring_before_the_original_is_refused_and_one_that_does_not_is_written(self):
        self.assertEqual(0, self.send(), self.stderr.getvalue())
        (original, original_wire, _), = self.written()

        self.assertNotEqual(0, self.send("--replaces", original, valid_for="5h"))
        self.assertIn("expiresAt", self.stderr.getvalue())
        self.assertEqual(1, self.notice_count())

        self.assertEqual(0, self.send("--replaces", original, valid_for="7h", content="改至中山國中避難所"),
                         self.stderr.getvalue())
        (correction, wire, record), = self.written()
        self.assertEqual(bytes.fromhex(original), wire[28:36])
        self.assertGreaterEqual(int.from_bytes(wire[20:28], "big"), int.from_bytes(original_wire[20:28], "big"))
        self.assertEqual(original, record["replaces"])
        self.assertEqual(correction, record["batchId"])

    def test_a_pure_revoke_is_written_and_a_second_one_refused(self):
        self.assertEqual(0, self.send(), self.stderr.getvalue())
        (original, original_wire, _), = self.written()

        self.assertEqual(0, self.run_tool("revoke", original), self.stderr.getvalue())

        (revoke, wire, record), = self.written()
        self.assertEqual(nf.KIND_BROADCAST, wire[1])
        self.assertEqual(original_wire[3], wire[3])  # 同一個 level
        self.assertEqual(original_wire[20:28], wire[20:28])  # 與原公告同時到期
        self.assertEqual(bytes.fromhex(original), wire[28:36])
        self.assertEqual(nf.HEADER_SIZE + nf.SIGNATURE_SIZE, len(wire))
        self.assertEqual(("broadcast", "", original), (record["kind"], record["content"], record["replaces"]))
        self.assertIsNotNone(read_as_owner(f"admin_notices/{original}"), "撤回不刪除原公告的文件")

        self.assertNotEqual(0, self.run_tool("revoke", original))
        self.assertIn(revoke, self.stderr.getvalue())
        self.assertEqual(2, self.notice_count())

    def test_a_split_targeted_batch_is_revoked_notice_by_notice(self):
        for i in range(6):
            self.register(self.member_uid, f"d{i}d{i}d{i}d{i}d{i}d{i}")
        self.assertEqual(0, self.send("--uid", self.member_uid), self.stderr.getvalue())
        batch = self.written()
        (batch_id,) = {record["batchId"] for _, _, record in batch}
        self.assertEqual(2, len(batch))

        self.assertEqual(0, self.run_tool("revoke", "--batch", batch_id), self.stderr.getvalue())

        revokes = self.written()
        self.assertEqual(sorted(message_id for message_id, _, _ in batch),
                         sorted(record["replaces"] for _, _, record in revokes))
        self.assertEqual([nf.KIND_BROADCAST] * 2, [wire[1] for _, wire, _ in revokes])

        self.assertNotEqual(0, self.run_tool("revoke", "--batch", batch_id))
        self.assertIn("沒有要撤回的", self.stderr.getvalue())

    def test_a_targeted_notice_is_corrected_only_by_a_targeted_notice(self):
        key = self.register(self.member_uid, "a1a1a1a1a1a1")
        self.assertEqual(0, self.send("--uid", self.member_uid, valid_for="2h"), self.stderr.getvalue())
        (original, _, _), = self.written()

        self.assertNotEqual(0, self.send("--replaces", original, valid_for="3h"))
        self.assertIn("--uid", self.stderr.getvalue())

        self.assertEqual(0, self.send("--replaces", original, "--uid", self.member_uid, valid_for="3h",
                                      content="改至中山國中避難所"), self.stderr.getvalue())
        (_, wire, record), = self.written()
        self.assertEqual((nf.KIND_TARGETED, bytes.fromhex(original)), (wire[1], wire[28:36]))
        self.assertEqual("改至中山國中避難所".encode(), nf.open_as_recipient(wire, key))
        self.assertEqual(original, record["replaces"])


if __name__ == "__main__":
    unittest.main()
