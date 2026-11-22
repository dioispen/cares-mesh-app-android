"""admin_notice_tool 的命令列行為：keygen 與 send。

Firebase 只在 HTTP 邊界換成假的（FakeFirebase），測試不會連到任何線上服務。
"""

import hashlib
import io
import json
import os
import re
import stat
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import admin_notice_tool as tool
import firebase_rest as fb
import notice_format as nf

TEST_SEED = hashlib.sha256(b"cares-admin-notice-test/admin").digest()
TEST_PUBLIC_HEX = "10f835a2f82b877a2c1c705ef3c71d3640a40b4e39f6ca4197c17eaefb05a176"


class ToolTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp))
        self.stdout, self.stderr = io.StringIO(), io.StringIO()

    def run_tool(self, *argv, **deps) -> int:
        deps.setdefault("stdout", self.stdout)
        deps.setdefault("stderr", self.stderr)
        return tool.main(list(argv), tool.Deps(**deps))


class KeygenTest(ToolTestCase):
    def test_writes_the_private_key_owner_only_and_prints_only_the_public_key(self):
        key_dir = self.tmp / "config" / "admin-notice"
        key_path = key_dir / "admin-ed25519-01.key"

        self.assertEqual(0, self.run_tool("keygen", "--out", str(key_path)))

        public_hex = self.stdout.getvalue()
        self.assertRegex(public_hex, r"^[0-9a-f]{64}\n$")
        self.assertEqual(0o600, stat.S_IMODE(key_path.stat().st_mode))
        # keygen 建立的每一層目錄都只給自己（例如 ~/.config/cares-mesh 與底下的 admin-notice）
        self.assertEqual(0o700, stat.S_IMODE(key_dir.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(key_dir.parent.stat().st_mode))
        key = tool.load_private_key(key_path)
        self.assertEqual(public_hex.strip(), nf.raw_public(key).hex())
        seed_hex = nf.raw_private(key).hex()
        self.assertNotIn(seed_hex, self.stdout.getvalue() + self.stderr.getvalue())

    def test_refuses_to_overwrite_an_existing_key_file(self):
        key_path = self.tmp / "admin-ed25519-01.key"
        key_path.write_text("existing\n")

        self.assertNotEqual(0, self.run_tool("keygen", "--out", str(key_path)))

        self.assertEqual("existing\n", key_path.read_text())
        self.assertEqual("", self.stdout.getvalue())


class PublishedPublicKeysTest(unittest.TestCase):
    """admin_public_keys.json 是 App 內建公鑰表的來源（#136）。"""

    def test_has_a_32_byte_key_for_key_id_0x01(self):
        keys = tool.load_public_keys(tool.PUBLIC_KEYS_PATH)
        self.assertEqual(32, len(keys[0x01]))
        self.assertNotIn(0x00, keys)  # 0x00 保留不用

    def test_never_publishes_the_test_vector_key(self):
        # 附錄 test vectors 的私鑰人人都算得出來，登記成正式公鑰等於誰都能發公告。
        keys = tool.load_public_keys(tool.PUBLIC_KEYS_PATH)
        self.assertNotIn(bytes.fromhex(TEST_PUBLIC_HEX), keys.values())


ISSUED_AT = 1792627200000  # 2026-10-22T00:00:00Z
CONTENT = "土石流警戒：請立即撤離至大同國小避難所"
ADMIN_UID = "uid-admin"


DAY = 24 * 3_600_000


@dataclass
class Device:
    """reporter_handles/{uid}/installations/{handle} 的一份登記；key 是這支手機的收件私鑰。"""
    uid: str
    handle: str
    key: X25519PrivateKey = None  # None：舊版 App 寫的，沒有 noticePublicKey
    registered_at: int = ISSUED_AT - DAY

    def fields(self) -> dict:
        fields = {"reporterHandle": fb.encode_value(self.handle),
                  "signingPublicKey": fb.encode_value(bytes(32)),
                  "registeredAt": fb.encode_value(fb.Timestamp(self.registered_at))}
        if self.key:
            fields["noticePublicKey"] = fb.encode_value(nf.raw_public(self.key))
        return fields


def device(uid: str, handle: str, *, registered_at=ISSUED_AT - DAY, legacy=False) -> Device:
    key = None if legacy else X25519PrivateKey.from_private_bytes(
        hashlib.sha256(f"device/{uid}/{handle}".encode()).digest())
    return Device(uid, handle, key, registered_at)


class FakeFirebase:
    """假的 Firebase Auth 與 Firestore REST：記下每個請求，回傳固定的結果。

    installations 是 Firestore 裡的登記；runQuery 只認發送工具會送的兩種查詢。
    """

    def __init__(self, uid=ADMIN_UID, commit_error=None, installations=(), query_error=None):
        self.uid, self.commit_error, self.query_error = uid, commit_error, query_error
        self.installations = list(installations)
        self.requests = []

    def post(self, url, body, headers):
        self.requests.append((url, body, headers))
        if "accounts:signInWithPassword" in url:
            return {"idToken": f"id-token-of-{self.uid}", "localId": self.uid}
        if url.endswith("documents:commit"):
            if self.commit_error:
                raise self.commit_error
            return {"writeResults": [{}, {}], "commitTime": "2026-10-22T00:00:01Z"}
        if url.endswith(":runQuery"):
            if self.query_error:
                raise self.query_error
            return self.run_query(url, body["structuredQuery"])
        raise AssertionError(f"unexpected request {url}")

    def run_query(self, url, query):
        parent = url.split("/documents", 1)[1].removesuffix(":runQuery")
        (source,) = query["from"]
        assert source["collectionId"] == "installations", query
        if source.get("allDescendants"):
            assert parent == "", url
            condition = query["where"]["fieldFilter"]
            assert (condition["field"]["fieldPath"], condition["op"]) == ("reporterHandle", "EQUAL"), query
            found = [d for d in self.installations if d.handle == condition["value"]["stringValue"]]
        else:
            uid = re.fullmatch(r"/reporter_handles/([^/]+)", parent).group(1)
            found = [d for d in self.installations if d.uid == uid]
        name = "projects/test-project/databases/(default)/documents/reporter_handles/{}/installations/{}"
        return [{"document": {"name": name.format(d.uid, d.handle), "fields": d.fields()},
                 "readTime": "2026-10-22T00:00:01Z"} for d in found] or [{"readTime": "2026-10-22T00:00:01Z"}]

    def queries(self):
        return [(url, body["structuredQuery"]) for url, body, _ in self.requests if url.endswith(":runQuery")]

    def urls(self):
        return [url for url, _, _ in self.requests]

    def commits(self):
        return [(body, headers) for url, body, headers in self.requests if url.endswith("documents:commit")]


def document(write) -> tuple[str, str]:
    """write 寫的是哪個 collection 的哪份文件。"""
    *_, collection, doc_id = write["update"]["name"].split("/")
    return collection, doc_id


def decode(value: dict):
    """Firestore REST 的 Value 轉回 Python 值（只涵蓋這個工具會寫的型別）。"""
    import base64
    (kind, raw), = value.items()
    return {"bytesValue": lambda: base64.b64decode(raw), "nullValue": lambda: None,
            "integerValue": lambda: int(raw),
            "arrayValue": lambda: [decode(v) for v in raw.get("values", [])],
            "mapValue": lambda: {k: decode(v) for k, v in raw.get("fields", {}).items()},
            }.get(kind, lambda: raw)()


class SendTestCase(ToolTestCase):
    def setUp(self):
        super().setUp()
        self.key_path = self.tmp / "admin-ed25519-01.key"
        self.key_path.write_text(TEST_SEED.hex() + "\n")
        os.chmod(self.key_path, 0o600)
        self.public_keys = self.tmp / "admin_public_keys.json"
        self.public_keys.write_text(json.dumps({"0x01": TEST_PUBLIC_HEX}))
        self.google_services = self.tmp / "google-services.json"
        self.google_services.write_text(json.dumps({
            "project_info": {"project_id": "test-project"},
            "client": [{"client_info": {"android_client_info": {"package_name": "com.bitchat.droid"}},
                        "api_key": [{"current_key": "test-api-key"}]}],
        }))
        self.firebase = FakeFirebase()
        self.env = {"CARES_ADMIN_PASSWORD": "correct horse"}
        self.prompts = []

    def send(self, *extra, content=CONTENT, valid_for="6h", level="urgent", **deps) -> int:
        argv = ["send", "--email", "admin@example.org", "--level", level, "--content", content,
                "--valid-for", valid_for, "--key", str(self.key_path), *extra]
        if "--dry-run" not in extra and "input" not in deps:
            argv.append("--yes")
        deps.setdefault("post", self.firebase.post)
        deps.setdefault("env", self.env)
        deps.setdefault("now_ms", lambda: ISSUED_AT)
        deps.setdefault("getpass", lambda prompt: self.prompts.append(prompt) or "typed password")
        deps.setdefault("public_keys_path", self.public_keys)
        deps.setdefault("google_services_path", self.google_services)
        return self.run_tool(*argv, **deps)

    def committed_writes(self) -> dict:
        commits = self.firebase.commits()
        self.assertEqual(1, len(commits), "兩份文件必須在同一次 commit 寫入")
        body, _ = commits[0]
        return {document(w)[0]: w for w in body["writes"]}


class SendBroadcastTest(SendTestCase):
    def test_writes_notice_and_record_in_one_commit_that_only_creates(self):
        self.assertEqual(0, self.send(), self.stderr.getvalue())

        writes = self.committed_writes()
        self.assertEqual({"admin_notices", "admin_notice_records"}, set(writes))
        notice_id = document(writes["admin_notices"])[1]
        self.assertRegex(notice_id, r"^[0-9a-f]{16}$")
        self.assertEqual(notice_id, document(writes["admin_notice_records"])[1])
        for w in writes.values():
            self.assertEqual({"exists": False}, w["currentDocument"])
            self.assertEqual([{"fieldPath": "createdAt", "setToServerValue": "REQUEST_TIME"}],
                             w["updateTransforms"])
        _, headers = self.firebase.commits()[0]
        self.assertEqual(f"Bearer id-token-of-{ADMIN_UID}", headers["Authorization"])

    def test_notice_has_exactly_the_fields_the_rules_allow(self):
        self.send()
        fields = self.committed_writes()["admin_notices"]["update"]["fields"]
        # createdAt 由 updateTransforms 補上伺服器時間
        self.assertEqual({"wire", "expiresAt", "createdBy"}, set(fields))
        self.assertEqual({"stringValue": ADMIN_UID}, fields["createdBy"])
        self.assertEqual({"timestampValue": "2026-10-22T06:00:00.000Z"}, fields["expiresAt"])

    def test_written_wire_verifies_with_the_published_public_key(self):
        self.send()
        notice = self.committed_writes()["admin_notices"]
        wire = decode(notice["update"]["fields"]["wire"])

        nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), wire)
        self.assertEqual(bytes.fromhex(document(notice)[1]), wire[4:12])
        self.assertEqual(bytes([nf.VERSION, nf.KIND_BROADCAST, 0x01, nf.LEVEL_URGENT]), wire[:4])
        self.assertEqual((1792627200000).to_bytes(8, "big"), wire[12:20])  # issuedAt
        self.assertEqual((1792648800000).to_bytes(8, "big"), wire[20:28])  # expiresAt = issuedAt + 6h
        self.assertEqual(bytes(8), wire[28:36])  # 沒有 replaces
        self.assertEqual(CONTENT, wire[36:-64].decode("utf-8"))

    def test_record_keeps_the_plaintext_and_the_operator(self):
        self.send(level="important")
        writes = self.committed_writes()
        notice_id = document(writes["admin_notices"])[1]
        record = {k: decode(v) for k, v in writes["admin_notice_records"]["update"]["fields"].items()}
        self.assertEqual({
            "kind": "broadcast",
            "level": "important",
            "content": CONTENT,
            "issuedAt": "2026-10-22T00:00:00.000Z",
            "expiresAt": "2026-10-22T06:00:00.000Z",
            "replaces": None,
            "batchId": notice_id,
            "createdBy": ADMIN_UID,
        }, record)

    def test_message_id_is_fresh_for_every_notice(self):
        self.send()
        self.send()
        ids = {document(body["writes"][0])[1] for body, _ in self.firebase.commits()}
        self.assertEqual(2, len(ids))


ALICE_PHONE = device("uid-alice", "a1a1a1a1a1a1")
ALICE_TABLET = device("uid-alice", "a2a2a2a2a2a2")
ALICE_OLD_APP = device("uid-alice", "a3a3a3a3a3a3", legacy=True)
BOB_PHONE = device("uid-bob", "b1b1b1b1b1b1")


class TargetedTestCase(SendTestCase):
    def setUp(self):
        super().setUp()
        self.firebase.installations = [ALICE_PHONE, ALICE_TABLET, ALICE_OLD_APP, BOB_PHONE]

    def notices(self) -> list[tuple[str, bytes, dict]]:
        """寫進同一次 commit 的每一則：(messageId, wire, 解碼後的 admin_notice_records)。"""
        (body, _), = self.firebase.commits()
        writes = {document(w): w for w in body["writes"]}
        notices = []
        for (collection, doc_id), w in writes.items():
            if collection == "admin_notices":
                record = writes[("admin_notice_records", doc_id)]["update"]["fields"]
                notices.append((doc_id, decode(w["update"]["fields"]["wire"]),
                                {k: decode(v) for k, v in record.items()}))
        self.assertEqual(len(writes), 2 * len(notices), "每則公告都要有一份 admin_notice_records")
        return notices

    def opened_by(self, wire: bytes, *devices: Device) -> list[bool]:
        nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), wire)
        return [nf.open_as_recipient(wire, d.key) == CONTENT.encode() for d in devices]


class SendTargetedByUidTest(TargetedTestCase):
    def test_every_device_the_account_registered_opens_the_notice(self):
        self.assertEqual(0, self.send("--uid", "uid-alice"), self.stderr.getvalue())

        (message_id, wire, record), = self.notices()
        self.assertEqual(bytes([nf.VERSION, nf.KIND_TARGETED, 0x01, nf.LEVEL_URGENT]), wire[:4])
        self.assertEqual(message_id, wire[4:12].hex())
        self.assertEqual([True, True, False], self.opened_by(wire, ALICE_PHONE, ALICE_TABLET, BOB_PHONE))
        self.assertEqual(2, wire[nf.HEADER_SIZE + 32])  # 舊版 App 的登記沒有 noticePublicKey，不算收件裝置

    def test_reads_every_installation_under_the_uid(self):
        self.send("--uid", "uid-alice")

        (url, query), = self.firebase.queries()
        self.assertEqual("https://firestore.googleapis.com/v1/projects/test-project/databases/(default)"
                         "/documents/reporter_handles/uid-alice:runQuery", url)
        self.assertEqual({"from": [{"collectionId": "installations"}]}, query)
        (_, _, headers), = [r for r in self.firebase.requests if r[0] == url]
        self.assertEqual(f"Bearer id-token-of-{ADMIN_UID}", headers["Authorization"])

    def test_record_names_the_recipients_as_the_operator_did_and_the_devices_it_was_encrypted_to(self):
        self.send("--uid", "uid-alice", level="important")

        (message_id, _, record), = self.notices()
        self.assertEqual({
            "kind": "targeted",
            "level": "important",
            "content": CONTENT,
            "issuedAt": "2026-10-22T00:00:00.000Z",
            "expiresAt": "2026-10-22T06:00:00.000Z",
            "replaces": None,
            "batchId": message_id,
            "createdBy": ADMIN_UID,
            "recipientUids": ["uid-alice"],
            "recipientHandles": [],
            "recipientCount": 2,
            "recipientDevices": [
                {"uid": "uid-alice", "reporterHandle": "a1a1a1a1a1a1", "noticePublicKey": nf.raw_public(ALICE_PHONE.key)},
                {"uid": "uid-alice", "reporterHandle": "a2a2a2a2a2a2", "noticePublicKey": nf.raw_public(ALICE_TABLET.key)},
            ],
        }, record)

    def test_the_notice_document_has_only_the_wire_and_no_recipient(self):
        self.send("--uid", "uid-alice")

        (body, _), = self.firebase.commits()
        (notice,) = [w for w in body["writes"] if document(w)[0] == "admin_notices"]
        self.assertEqual({"wire", "expiresAt", "createdBy"}, set(notice["update"]["fields"]))
        self.assertNotIn(b"uid-alice", decode(notice["update"]["fields"]["wire"]))


class SendTargetedByHandleTest(TargetedTestCase):
    def test_the_device_registered_under_the_handle_opens_the_notice(self):
        self.assertEqual(0, self.send("--handle", "b1b1b1b1b1b1"), self.stderr.getvalue())

        (_, wire, record), = self.notices()
        self.assertEqual([False, False, True], self.opened_by(wire, ALICE_PHONE, ALICE_TABLET, BOB_PHONE))
        self.assertEqual(([], ["b1b1b1b1b1b1"], 1), (record["recipientUids"], record["recipientHandles"],
                                                    record["recipientCount"]))
        self.assertEqual("", self.stderr.getvalue())

    def test_looks_the_handle_up_with_a_collection_group_query(self):
        self.send("--handle", "B1B1B1B1B1B1")  # 大小寫不拘，存成小寫

        (url, query), = self.firebase.queries()
        self.assertTrue(url.endswith("/projects/test-project/databases/(default)/documents:runQuery"), url)
        self.assertEqual({
            "from": [{"collectionId": "installations", "allDescendants": True}],
            "where": {"fieldFilter": {"field": {"fieldPath": "reporterHandle"}, "op": "EQUAL",
                                      "value": {"stringValue": "b1b1b1b1b1b1"}}},
        }, query)

    def test_when_several_accounts_claim_the_handle_the_newest_registration_is_used_and_the_operator_warned(self):
        earlier = device("uid-earlier", "c1c1c1c1c1c1", registered_at=ISSUED_AT - 3 * DAY)
        newest = device("uid-newest", "c1c1c1c1c1c1", registered_at=ISSUED_AT - DAY)
        self.firebase.installations += [newest, earlier]

        self.assertEqual(0, self.send("--handle", "c1c1c1c1c1c1"), self.stderr.getvalue())

        (_, wire, _), = self.notices()
        self.assertEqual([True, False], self.opened_by(wire, newest, earlier))
        warning = self.stderr.getvalue()
        self.assertIn("警告", warning)
        self.assertIn("uid-newest", warning)
        self.assertIn("uid-earlier", warning)
        self.assertIn("冒領", warning)


class SendTargetedSplitTest(TargetedTestCase):
    def test_six_devices_become_two_notices_with_one_batch_id_in_one_commit(self):
        many = [device("uid-many", f"d{i}d{i}d{i}d{i}d{i}d{i}") for i in range(6)]
        self.firebase.installations += many

        self.assertEqual(0, self.send("--uid", "uid-many"), self.stderr.getvalue())

        notices = self.notices()  # 只有一次 commit
        self.assertEqual(2, len(notices))
        message_ids = {message_id for message_id, _, _ in notices}
        self.assertEqual(2, len(message_ids))
        (batch_id,) = {record["batchId"] for _, _, record in notices}
        self.assertIn(batch_id, message_ids)
        self.assertEqual([3, 3], [record["recipientCount"] for _, _, record in notices])
        # 每台裝置恰好解得開其中一則
        opened = [self.opened_by(wire, *many) for _, wire, _ in notices]
        self.assertEqual([1] * 6, [sum(column) for column in zip(*opened)])
        for (_, wire, record), opens in zip(notices, opened):
            self.assertEqual(["uid-many"], record["recipientUids"])
            self.assertEqual({d.handle for d, ok in zip(many, opens) if ok},
                             {r["reporterHandle"] for r in record["recipientDevices"]})

    def test_five_devices_stay_one_notice(self):
        self.firebase.installations += [device("uid-five", f"e{i}e{i}e{i}e{i}e{i}e{i}") for i in range(5)]

        self.send("--uid", "uid-five")

        (message_id, wire, record), = self.notices()
        self.assertEqual((5, message_id), (record["recipientCount"], record["batchId"]))

    def test_a_device_named_by_uid_and_by_handle_is_encrypted_to_once(self):
        self.assertEqual(0, self.send("--uid", "uid-bob", "--handle", "b1b1b1b1b1b1", "--uid", "uid-bob"))

        (_, wire, record), = self.notices()
        self.assertEqual(1, record["recipientCount"])
        self.assertEqual((["uid-bob"], ["b1b1b1b1b1b1"]), (record["recipientUids"], record["recipientHandles"]))
        self.assertEqual([True], self.opened_by(wire, BOB_PHONE))


class SendTargetedWithoutRecipientDevicesTest(TargetedTestCase):
    def assert_nothing_sent(self, *targets) -> str:
        self.assertNotEqual(0, self.send(*targets))
        self.assertEqual([], self.firebase.commits())
        self.assertNotIn("已寫入", self.stdout.getvalue())
        return self.stderr.getvalue()

    def test_an_account_with_no_registered_device_stops_the_whole_send(self):
        error = self.assert_nothing_sent("--uid", "uid-alice", "--uid", "uid-nobody")
        self.assertIn("找不到收件裝置", error)
        self.assertIn("uid-nobody", error)
        self.assertNotIn("uid-alice：", error)

    def test_an_account_whose_devices_all_run_the_old_app(self):
        self.firebase.installations.append(device("uid-legacy", "f1f1f1f1f1f1", legacy=True))
        error = self.assert_nothing_sent("--uid", "uid-legacy")
        self.assertIn("uid-legacy", error)
        self.assertIn("noticePublicKey", error)

    def test_a_handle_nobody_registered(self):
        self.assertIn("a0a0a0a0a0a0", self.assert_nothing_sent("--handle", "a0a0a0a0a0a0"))

    def test_a_handle_whose_newest_registration_has_no_notice_key(self):
        self.firebase.installations += [device("uid-x", "f2f2f2f2f2f2", registered_at=ISSUED_AT - 3 * DAY),
                                        device("uid-y", "f2f2f2f2f2f2", legacy=True)]
        error = self.assert_nothing_sent("--handle", "f2f2f2f2f2f2")
        self.assertIn("uid-y", error)
        self.assertIn("noticePublicKey", error)


class SendTargetedWarningsAndFlowTest(TargetedTestCase):
    def test_a_registration_older_than_30_days_is_warned_about_but_still_encrypted_to(self):
        stale = device("uid-stale", "f3f3f3f3f3f3", registered_at=ISSUED_AT - 31 * DAY)
        recent = device("uid-stale", "f4f4f4f4f4f4", registered_at=ISSUED_AT - 29 * DAY)
        self.firebase.installations += [stale, recent]

        self.assertEqual(0, self.send("--uid", "uid-stale"), self.stderr.getvalue())

        (_, wire, _), = self.notices()
        self.assertEqual([True, True], self.opened_by(wire, stale, recent))
        warning = self.stderr.getvalue()
        self.assertIn("30 天", warning)
        self.assertIn("f3f3f3f3f3f3", warning)
        self.assertNotIn("f4f4f4f4f4f4", warning)

    def test_dry_run_looks_the_devices_up_and_prints_the_wires_without_writing(self):
        self.assertEqual(0, self.send("--uid", "uid-alice", "--dry-run"), self.stderr.getvalue())

        self.assertEqual([], self.firebase.commits())
        self.assertEqual(1, len(self.firebase.queries()))
        wire_hex = re.search(r"wire [0-9a-f]{16}（\d+ bytes）：([0-9a-f]+)", self.stdout.getvalue()).group(1)
        self.assertEqual([True, True], self.opened_by(bytes.fromhex(wire_hex), ALICE_PHONE, ALICE_TABLET))

    def test_the_operator_confirms_after_seeing_the_devices(self):
        prompts = []

        def answer(prompt):
            prompts.append(self.stdout.getvalue())
            return "no"

        self.assertNotEqual(0, self.send("--uid", "uid-alice", input=answer))

        self.assertEqual([], self.firebase.commits())
        self.assertIn("a1a1a1a1a1a1", prompts[0])
        self.assertIn("a2a2a2a2a2a2", prompts[0])

    def test_a_query_the_rules_reject_is_reported(self):
        self.firebase.query_error = fb.FirebaseError(403, "PERMISSION_DENIED", "Missing or insufficient permissions.")
        self.assertNotEqual(0, self.send("--uid", "uid-alice"))
        self.assertIn("Administrator", self.stderr.getvalue())
        self.assertEqual([], self.firebase.commits())

    def test_a_missing_collection_group_index_is_explained(self):
        self.firebase.query_error = fb.FirebaseError(400, "FAILED_PRECONDITION", "The query requires an index.")
        self.assertNotEqual(0, self.send("--handle", "b1b1b1b1b1b1"))
        self.assertIn("collection group 索引", self.stderr.getvalue())


class SendTargetedRefusesBeforeContactingFirebaseTest(TargetedTestCase):
    def assert_refused(self, *extra, **kwargs):
        self.assertNotEqual(0, self.send(*extra, **kwargs))
        self.assertEqual([], self.firebase.requests)
        self.assertEqual([], self.prompts)

    def test_empty_content(self):
        self.assert_refused("--uid", "uid-alice", content="")

    def test_content_over_300_bytes(self):
        self.assert_refused("--uid", "uid-alice", content="警" * 101)

    def test_validity_over_24_hours(self):
        self.assert_refused("--uid", "uid-alice", valid_for="24h1m")

    def test_key_file_that_does_not_match_the_published_public_key(self):
        self.key_path.write_text(nf.raw_private(Ed25519PrivateKey.generate()).hex() + "\n")
        self.assert_refused("--uid", "uid-alice")
        self.assertIn("公鑰不符", self.stderr.getvalue())

    def test_malformed_targets(self):
        for target in [("--uid", "uid/../admins"), ("--uid", ""), ("--handle", "b1b1b1"), ("--handle", "zzzzzzzzzzzz")]:
            with self.subTest(target), self.assertRaises(SystemExit):
                self.send(*target)
        self.assertEqual([], self.firebase.requests)


class SendRefusesBeforeContactingFirebaseTest(SendTestCase):
    def assert_refused(self, *extra, **kwargs):
        self.assertNotEqual(0, self.send(*extra, **kwargs))
        self.assertEqual([], self.firebase.requests)
        self.assertEqual([], self.prompts)

    def test_content_over_300_bytes(self):
        self.assert_refused(content="警" * 101)
        self.assertIn("300 bytes", self.stderr.getvalue())

    def test_empty_content(self):
        self.assert_refused(content="")

    def test_validity_over_24_hours(self):
        self.assert_refused(valid_for="24h1m")
        self.assertEqual(0, self.send(valid_for="24h"))

    def test_malformed_validity(self):
        for bad in ["", "6", "6d", "-1h", "h"]:
            with self.subTest(bad), self.assertRaises(SystemExit):
                self.send(valid_for=bad)
        self.assertEqual([], self.firebase.requests)

    def test_key_file_that_does_not_match_the_published_public_key(self):
        other = Ed25519PrivateKey.generate()
        self.key_path.write_text(nf.raw_private(other).hex() + "\n")
        self.assert_refused()
        self.assertIn("公鑰不符", self.stderr.getvalue())

    def test_key_id_without_a_published_public_key(self):
        self.assert_refused("--key-id", "0x02")

    def test_operator_does_not_confirm(self):
        self.assert_refused(input=lambda prompt: "y")

    def test_dry_run_signs_and_prints_the_wire_without_signing_in(self):
        self.assertEqual(0, self.send("--dry-run"))
        self.assertEqual([], self.firebase.requests)
        self.assertEqual([], self.prompts)
        wire_hex = re.search(r"wire（\d+ bytes）：([0-9a-f]+)", self.stdout.getvalue()).group(1)
        nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), bytes.fromhex(wire_hex))

    def test_only_one_emulator_host_set(self):
        self.assert_refused(env={**self.env, "FIRESTORE_EMULATOR_HOST": "127.0.0.1:8080"})
        self.assert_refused(env={**self.env, "FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:9099"})


class SendCredentialsAndEndpointsTest(SendTestCase):
    def sign_in_request(self):
        (url, body, _), = [r for r in self.firebase.requests if "signInWithPassword" in r[0]]
        return url, body

    def test_signs_in_to_production_with_the_app_api_key(self):
        self.send()
        url, body = self.sign_in_request()
        self.assertEqual("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=test-api-key", url)
        self.assertEqual("admin@example.org", body["email"])
        self.assertEqual("https://firestore.googleapis.com/v1/projects/test-project/databases/(default)/documents:commit",
                         self.firebase.urls()[-1])

    def test_password_comes_from_the_environment_variable(self):
        self.send()
        self.assertEqual("correct horse", self.sign_in_request()[1]["password"])
        self.assertEqual([], self.prompts)

    def test_password_is_prompted_for_when_the_environment_variable_is_unset(self):
        self.send(env={})
        self.assertEqual("typed password", self.sign_in_request()[1]["password"])
        self.assertEqual(1, len(self.prompts))

    def test_password_cannot_be_given_on_the_command_line(self):
        with self.assertRaises(SystemExit):
            self.send("--password", "hunter2")
        self.assertEqual([], self.firebase.requests)

    def test_emulators_from_the_environment(self):
        self.send("--project", "demo-cares", env={**self.env,
                                                  "FIRESTORE_EMULATOR_HOST": "127.0.0.1:8080",
                                                  "FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:9099"})
        self.assertEqual([
            "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=test-api-key",
            "http://127.0.0.1:8080/v1/projects/demo-cares/databases/(default)/documents:commit",
        ], self.firebase.urls())

    def test_commit_rejected_by_the_rules_is_reported(self):
        self.firebase.commit_error = fb.FirebaseError(403, "PERMISSION_DENIED", "Missing or insufficient permissions.")
        self.assertNotEqual(0, self.send())
        self.assertIn("PERMISSION_DENIED", self.stderr.getvalue())
        self.assertIn("Administrator", self.stderr.getvalue())
        self.assertNotIn("已寫入", self.stdout.getvalue())

    def test_failed_sign_in_writes_nothing(self):
        def reject(url, body, headers):
            raise fb.FirebaseError(400, "INVALID_LOGIN_CREDENTIALS", "INVALID_LOGIN_CREDENTIALS")
        self.assertNotEqual(0, self.send(post=reject))
        self.assertIn("登入失敗", self.stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
