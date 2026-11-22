"""admin_notice_tool 的取代與撤回：send --replaces、revoke、revoke --batch（#139）。

docs/ADMIN_NOTICE_V1.md「撤回與取代」與「給管理後台的介面契約」。Firebase 只在 HTTP 邊界換成
假的，admin_notice_records 放在 FakeFirebase 的記憶體裡，測試不連任何線上服務。
"""

import re
import unittest

import firebase_rest as fb
import notice_format as nf
from test_admin_notice_tool import (
    ADMIN_UID, ALICE_PHONE, ALICE_TABLET, BOB_PHONE, CONTENT, ISSUED_AT, TEST_PUBLIC_HEX,
    FakeFirebase, SendTestCase, decode, device, document,
)

HOUR = 3_600_000
ORIGINAL = "a1b2c3d4e5f60718"
SIBLING = "0f1e2d3c4b5a6978"
RECORDS = "admin_notice_records"
DOCUMENTS = "projects/test-project/databases/(default)/documents"


def record(*, kind="broadcast", level="urgent", content=CONTENT, issued_at=ISSUED_AT - HOUR,
           expires_at=ISSUED_AT + 5 * HOUR, replaces=None, batch_id=ORIGINAL) -> dict:
    """admin_notice_records 的一份留存，欄位照發送工具寫的（docs「集合」）。"""
    return {"kind": kind, "level": level, "content": content, "issuedAt": fb.Timestamp(issued_at),
            "expiresAt": fb.Timestamp(expires_at), "replaces": replaces, "batchId": batch_id,
            "createdBy": ADMIN_UID}


class FakeFirebaseWithRecords(FakeFirebase):
    """FakeFirebase 加上 admin_notice_records：batchGet 讀得到、runQuery 查得到，commit 寫進去的也是。"""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.records = {}

    def post(self, url, body, headers):
        if url.endswith("documents:batchGet"):
            self.requests.append((url, body, headers))
            return [self.found(name) for name in body["documents"]]
        if url.endswith(":runQuery") and body["structuredQuery"]["from"] == [{"collectionId": RECORDS}]:
            self.requests.append((url, body, headers))
            condition = body["structuredQuery"]["where"]["fieldFilter"]
            assert condition["op"] == "EQUAL", condition
            field, value = condition["field"]["fieldPath"], fb.decode_value(condition["value"])
            found = [{"document": self.document(doc_id), "readTime": "2026-10-22T00:00:01Z"}
                     for doc_id, fields in sorted(self.records.items()) if fields.get(field) == value]
            return found or [{"readTime": "2026-10-22T00:00:01Z"}]
        response = super().post(url, body, headers)
        if url.endswith("documents:commit") and not self.commit_error:
            for write in body["writes"]:
                collection, doc_id = document(write)
                if collection == RECORDS:
                    self.records[doc_id] = {k: fb.decode_value(v) for k, v in write["update"]["fields"].items()}
        return response

    def document(self, doc_id):
        return {"name": f"{DOCUMENTS}/{RECORDS}/{doc_id}",
                "fields": {k: fb.encode_value(v) for k, v in self.records[doc_id].items()}}

    def found(self, name):
        doc_id = name.rsplit("/", 1)[1]
        if name.startswith(f"{DOCUMENTS}/{RECORDS}/") and doc_id in self.records:
            return {"found": self.document(doc_id), "readTime": "2026-10-22T00:00:01Z"}
        return {"missing": name, "readTime": "2026-10-22T00:00:01Z"}

    def batch_gets(self):
        return [(body, headers) for url, body, headers in self.requests if url.endswith("documents:batchGet")]


class ReplaceTestCase(SendTestCase):
    def setUp(self):
        super().setUp()
        self.firebase = FakeFirebaseWithRecords()
        self.firebase.records[ORIGINAL] = record()

    def written(self) -> list:
        """這次 commit 寫入的每一則：(messageId, wire, 解碼後的 admin_notice_records)。"""
        (body, _), = self.firebase.commits()
        writes = {document(w): w for w in body["writes"]}
        for w in body["writes"]:
            self.assertEqual({"exists": False}, w["currentDocument"], "只新增，不改也不刪任何文件")
        notices = []
        for (collection, doc_id), w in writes.items():
            if collection == "admin_notices":
                fields = writes[(RECORDS, doc_id)]["update"]["fields"]
                wire = decode(w["update"]["fields"]["wire"])
                nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), wire)
                notices.append((doc_id, wire, {k: fb.decode_value(v) for k, v in fields.items()}))
        self.assertEqual(len(writes), 2 * len(notices))
        return notices

    def revoke(self, *target, **deps) -> int:
        argv = ["revoke", "--email", "admin@example.org", "--key", str(self.key_path), *target]
        if "--dry-run" not in target and "input" not in deps:
            argv.append("--yes")
        deps.setdefault("post", self.firebase.post)
        deps.setdefault("env", self.env)
        deps.setdefault("now_ms", lambda: ISSUED_AT)
        deps.setdefault("getpass", lambda prompt: self.prompts.append(prompt) or "typed password")
        deps.setdefault("public_keys_path", self.public_keys)
        deps.setdefault("google_services_path", self.google_services)
        return self.run_tool(*argv, **deps)

    def assert_refused(self, exit_code: int, *phrases: str):
        self.assertNotEqual(0, exit_code)
        self.assertEqual([], self.firebase.commits())
        for phrase in phrases:
            self.assertIn(phrase, self.stderr.getvalue())


# ---- send --replaces：更正 ---------------------------------------------------

class SendCorrectionTest(ReplaceTestCase):
    def test_a_correction_names_the_replaced_notice_in_its_wire_and_its_record(self):
        self.assertEqual(0, self.send("--replaces", ORIGINAL, valid_for="7h"), self.stderr.getvalue())

        (message_id, wire, saved), = self.written()
        self.assertEqual(bytes.fromhex(ORIGINAL), wire[28:36])
        self.assertEqual(nf.KIND_BROADCAST, wire[1])
        self.assertEqual(CONTENT, wire[36:-64].decode("utf-8"))
        self.assertEqual(ORIGINAL, saved["replaces"])
        self.assertEqual(message_id, saved["batchId"])
        self.assertIn(ORIGINAL, self.stdout.getvalue())

    def test_reads_the_replaced_notice_s_record_as_the_administrator(self):
        self.send("--replaces", ORIGINAL)

        (body, headers), = self.firebase.batch_gets()
        self.assertEqual([f"{DOCUMENTS}/{RECORDS}/{ORIGINAL}"], body["documents"])
        self.assertEqual(f"Bearer id-token-of-{ADMIN_UID}", headers["Authorization"])

    def test_a_correction_may_expire_exactly_with_the_replaced_notice(self):
        self.assertEqual(0, self.send("--replaces", ORIGINAL, valid_for="5h"), self.stderr.getvalue())

    def test_a_correction_expiring_before_the_replaced_notice_is_refused(self):
        self.assert_refused(self.send("--replaces", ORIGINAL, valid_for="4h59m"), "expiresAt", "--valid-for 5h")

    def test_an_unknown_message_id_is_refused(self):
        self.assert_refused(self.send("--replaces", "ffffffffffffffff"), "ffffffffffffffff", "找不到")

    def test_a_revoke_cannot_be_corrected(self):
        self.firebase.records["5566778899aabbcc"] = record(content="", replaces=ORIGINAL, batch_id="5566778899aabbcc")

        self.assert_refused(self.send("--replaces", "5566778899aabbcc"), "撤回")

    def test_a_notice_already_replaced_is_refused_and_the_replacement_named(self):
        self.firebase.records["c0c0c0c0c0c0c0c0"] = record(replaces=ORIGINAL, batch_id="c0c0c0c0c0c0c0c0")

        self.assert_refused(self.send("--replaces", ORIGINAL), "c0c0c0c0c0c0c0c0")

    def test_a_targeted_notice_is_not_corrected_by_a_broadcast(self):
        self.firebase.records[ORIGINAL] = record(kind="targeted")

        self.assert_refused(self.send("--replaces", ORIGINAL), "定向", "--uid")

    def test_dry_run_checks_the_replaced_notice_but_writes_nothing(self):
        self.assertEqual(0, self.send("--replaces", ORIGINAL, "--dry-run"), self.stderr.getvalue())

        self.assertEqual(1, len(self.firebase.batch_gets()))
        self.assertEqual([], self.firebase.commits())
        self.assertIn("沒有寫入", self.stdout.getvalue())

    def test_dry_run_still_refuses_a_correction_that_expires_too_early(self):
        self.assert_refused(self.send("--replaces", ORIGINAL, "--dry-run", valid_for="1h"), "expiresAt")

    def test_content_over_300_bytes_is_refused_before_signing_in(self):
        self.assert_refused(self.send("--replaces", ORIGINAL, content="警" * 101), "300 bytes")
        self.assertEqual([], self.firebase.requests)

    def test_replaces_must_be_a_message_id(self):
        for bad in ["A1B2C3D4E5F60718", "a1b2c3d4", "admin_notices/a1b2c3d4e5f60718"]:
            with self.subTest(bad), self.assertRaises(SystemExit):
                self.send("--replaces", bad)
        self.assertEqual([], self.firebase.requests)

    def test_the_operator_confirms_after_seeing_what_is_replaced(self):
        prompts = []
        self.assertEqual(1, self.send("--replaces", ORIGINAL, input=lambda p: prompts.append(p) or "no"))

        self.assertEqual([], self.firebase.commits())
        self.assertEqual(1, len(prompts))
        self.assertIn(ORIGINAL, self.stdout.getvalue())

    def test_correcting_one_notice_of_a_batch_warns_that_the_rest_stay(self):
        self.firebase.records[ORIGINAL] = record(kind="targeted", batch_id=ORIGINAL)
        self.firebase.records[SIBLING] = record(kind="targeted", batch_id=ORIGINAL)
        self.firebase.installations = [ALICE_PHONE]

        self.assertEqual(0, self.send("--replaces", ORIGINAL, "--uid", "uid-alice"), self.stderr.getvalue())

        self.assertIn(SIBLING, self.stderr.getvalue())
        self.assertIn("revoke --batch", self.stderr.getvalue())


class SendTargetedCorrectionTest(ReplaceTestCase):
    def setUp(self):
        super().setUp()
        self.firebase.records[ORIGINAL] = record(kind="targeted")
        self.firebase.installations = [ALICE_PHONE, ALICE_TABLET, BOB_PHONE]

    def test_a_targeted_notice_is_corrected_by_a_targeted_notice_only_its_recipients_open(self):
        self.assertEqual(0, self.send("--replaces", ORIGINAL, "--uid", "uid-alice"), self.stderr.getvalue())

        (message_id, wire, saved), = self.written()
        self.assertEqual(nf.KIND_TARGETED, wire[1])
        self.assertEqual(bytes.fromhex(ORIGINAL), wire[28:36])
        self.assertEqual([True, True, False], [nf.open_as_recipient(wire, d.key) == CONTENT.encode()
                                               for d in (ALICE_PHONE, ALICE_TABLET, BOB_PHONE)])
        self.assertEqual(ORIGINAL, saved["replaces"])
        self.assertEqual("targeted", saved["kind"])

    def test_a_correction_split_into_several_notices_replaces_the_original_in_each(self):
        many = [device("uid-many", f"d{i}d{i}d{i}d{i}d{i}d{i}") for i in range(6)]
        self.firebase.installations += many

        self.assertEqual(0, self.send("--replaces", ORIGINAL, "--uid", "uid-many"), self.stderr.getvalue())

        notices = self.written()
        self.assertEqual(2, len(notices))
        self.assertEqual([bytes.fromhex(ORIGINAL)] * 2, [wire[28:36] for _, wire, _ in notices])
        self.assertEqual([ORIGINAL] * 2, [saved["replaces"] for _, _, saved in notices])

    def test_the_expiry_rule_holds_for_a_targeted_correction_too(self):
        self.assert_refused(self.send("--replaces", ORIGINAL, "--uid", "uid-alice", valid_for="1h"), "expiresAt")

    def test_a_broadcast_corrected_by_a_targeted_notice_is_warned_about(self):
        self.firebase.records[ORIGINAL] = record(kind="broadcast")

        self.assertEqual(0, self.send("--replaces", ORIGINAL, "--uid", "uid-alice"), self.stderr.getvalue())

        self.assertIn("廣播", self.stderr.getvalue())


# ---- revoke：純撤回 ----------------------------------------------------------

class RevokeTest(ReplaceTestCase):
    def test_a_pure_revoke_is_an_empty_broadcast_naming_the_notice_and_expiring_with_it(self):
        self.firebase.records[ORIGINAL] = record(level="important")

        self.assertEqual(0, self.revoke(ORIGINAL), self.stderr.getvalue())

        (message_id, wire, saved), = self.written()
        self.assertEqual(bytes([nf.VERSION, nf.KIND_BROADCAST, 0x01, nf.LEVEL_IMPORTANT]), wire[:4])
        self.assertEqual(ISSUED_AT.to_bytes(8, "big"), wire[12:20])
        self.assertEqual((ISSUED_AT + 5 * HOUR).to_bytes(8, "big"), wire[20:28])
        self.assertEqual(bytes.fromhex(ORIGINAL), wire[28:36])
        self.assertEqual(nf.HEADER_SIZE + nf.SIGNATURE_SIZE, len(wire), "body 是空的")
        self.assertEqual({"kind": "broadcast", "level": "important", "content": "", "replaces": ORIGINAL,
                          "batchId": message_id, "issuedAt": fb.Timestamp(ISSUED_AT),
                          "expiresAt": fb.Timestamp(ISSUED_AT + 5 * HOUR), "createdBy": ADMIN_UID},
                         saved)

    def test_a_targeted_notice_is_revoked_with_a_broadcast_too(self):
        self.firebase.records[ORIGINAL] = record(kind="targeted")

        self.assertEqual(0, self.revoke(ORIGINAL), self.stderr.getvalue())

        (_, wire, saved), = self.written()
        self.assertEqual(nf.KIND_BROADCAST, wire[1])
        self.assertEqual("broadcast", saved["kind"])

    def test_a_notice_about_to_expire_is_revoked_for_at_least_an_hour(self):
        self.firebase.records[ORIGINAL] = record(expires_at=ISSUED_AT + 5 * 60_000)

        self.assertEqual(0, self.revoke(ORIGINAL), self.stderr.getvalue())

        (_, wire, _), = self.written()
        self.assertEqual((ISSUED_AT + HOUR).to_bytes(8, "big"), wire[20:28])

    def test_a_notice_expiring_more_than_24_hours_from_now_is_refused(self):
        # 原公告來自時鐘快了的操作者：撤回撐不到它過期，而 24 小時已經是上限。
        self.firebase.records[ORIGINAL] = record(issued_at=ISSUED_AT + 2 * HOUR, expires_at=ISSUED_AT + 25 * HOUR)

        self.assert_refused(self.revoke(ORIGINAL), "24 小時")

    def test_an_unknown_message_id_is_refused(self):
        self.assert_refused(self.revoke("ffffffffffffffff"), "找不到")

    def test_a_notice_is_revoked_once(self):
        self.assertEqual(0, self.revoke(ORIGINAL), self.stderr.getvalue())
        (revoke_id, _, _), = self.written()
        self.firebase.requests.clear()

        self.assert_refused(self.revoke(ORIGINAL), revoke_id)

    def test_a_revoke_cannot_be_revoked(self):
        self.firebase.records["5566778899aabbcc"] = record(content="", replaces=ORIGINAL, batch_id="5566778899aabbcc")

        self.assert_refused(self.revoke("5566778899aabbcc"), "撤回")

    def test_the_operator_confirms_after_seeing_what_is_revoked(self):
        self.assertEqual(1, self.revoke(ORIGINAL, input=lambda prompt: "y"))

        self.assertEqual([], self.firebase.commits())
        self.assertIn(CONTENT, self.stdout.getvalue())

    def test_dry_run_prints_the_signed_revoke_without_writing(self):
        self.assertEqual(0, self.revoke(ORIGINAL, "--dry-run"), self.stderr.getvalue())

        self.assertEqual([], self.firebase.commits())
        wire = bytes.fromhex(re.search(r"wire [0-9a-f]{16}（\d+ bytes）：([0-9a-f]+)", self.stdout.getvalue()).group(1))
        nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), wire)
        self.assertEqual(bytes.fromhex(ORIGINAL), wire[28:36])

    def test_needs_exactly_one_of_a_message_id_and_a_batch(self):
        for target in [(), (ORIGINAL, "--batch", ORIGINAL)]:
            with self.subTest(target), self.assertRaises(SystemExit):
                self.revoke(*target)
        self.assertEqual([], self.firebase.requests)

    def test_a_key_file_that_does_not_match_is_refused_before_signing_in(self):
        self.key_path.write_text("11" * 32 + "\n")

        self.assert_refused(self.revoke(ORIGINAL), "公鑰不符")
        self.assertEqual([], self.firebase.requests)


class RevokeBatchTest(ReplaceTestCase):
    def setUp(self):
        super().setUp()
        self.firebase.records[ORIGINAL] = record(kind="targeted", batch_id=ORIGINAL)
        self.firebase.records[SIBLING] = record(kind="targeted", batch_id=ORIGINAL, expires_at=ISSUED_AT + 5 * HOUR)
        self.firebase.records["7a5b3c1d9e8f6a42"] = record(batch_id="7a5b3c1d9e8f6a42")  # 另一批

    def test_every_notice_of_the_batch_gets_its_own_revoke_in_one_commit(self):
        self.assertEqual(0, self.revoke("--batch", ORIGINAL), self.stderr.getvalue())

        revokes = self.written()
        self.assertEqual(sorted([ORIGINAL, SIBLING]), sorted(saved["replaces"] for _, _, saved in revokes))
        self.assertEqual(2, len({message_id for message_id, _, _ in revokes}))
        for message_id, wire, saved in revokes:
            self.assertEqual(nf.KIND_BROADCAST, wire[1])
            self.assertEqual(bytes.fromhex(saved["replaces"]), wire[28:36])
            self.assertEqual(message_id, saved["batchId"])

    def test_looks_the_batch_up_by_batch_id(self):
        self.revoke("--batch", ORIGINAL)

        (url, query), = [(u, q) for u, q in self.firebase.queries() if q["where"]["fieldFilter"]["field"]["fieldPath"] == "batchId"]
        self.assertEqual(f"https://firestore.googleapis.com/v1/{DOCUMENTS}:runQuery", url)
        self.assertEqual([{"collectionId": RECORDS}], query["from"])
        self.assertEqual({"stringValue": ORIGINAL}, query["where"]["fieldFilter"]["value"])

    def test_notices_of_the_batch_already_replaced_are_skipped(self):
        self.firebase.records["c0c0c0c0c0c0c0c0"] = record(replaces=SIBLING, batch_id="c0c0c0c0c0c0c0c0")

        self.assertEqual(0, self.revoke("--batch", ORIGINAL), self.stderr.getvalue())

        (_, _, saved), = self.written()
        self.assertEqual(ORIGINAL, saved["replaces"])
        self.assertIn(SIBLING, self.stderr.getvalue())

    def test_a_batch_with_nothing_left_to_revoke_is_refused(self):
        self.assertEqual(0, self.revoke("--batch", ORIGINAL))
        self.firebase.requests.clear()

        self.assert_refused(self.revoke("--batch", ORIGINAL), "沒有要撤回的")

    def test_an_unknown_batch_is_refused(self):
        self.assert_refused(self.revoke("--batch", "ffffffffffffffff"), "ffffffffffffffff")


if __name__ == "__main__":
    unittest.main()
