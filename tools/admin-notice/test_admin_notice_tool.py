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
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

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


ISSUED_AT = 1792627200000  # 2026-10-22T00:00:00Z
CONTENT = "土石流警戒：請立即撤離至大同國小避難所"
ADMIN_UID = "uid-admin"


class FakeFirebase:
    """假的 Firebase Auth 與 Firestore REST：記下每個請求，回傳固定的結果。"""

    def __init__(self, uid=ADMIN_UID, commit_error=None):
        self.uid, self.commit_error = uid, commit_error
        self.requests = []

    def post(self, url, body, headers):
        self.requests.append((url, body, headers))
        if "accounts:signInWithPassword" in url:
            return {"idToken": f"id-token-of-{self.uid}", "localId": self.uid}
        if url.endswith("documents:commit"):
            if self.commit_error:
                raise self.commit_error
            return {"writeResults": [{}, {}], "commitTime": "2026-10-22T00:00:01Z"}
        raise AssertionError(f"unexpected request {url}")

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
    return {"bytesValue": lambda: base64.b64decode(raw), "nullValue": lambda: None}.get(kind, lambda: raw)()


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
