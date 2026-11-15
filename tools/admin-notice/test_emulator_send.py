"""send 對著 Firebase emulator 跑一次：REST commit 真的經過 firestore.rules。

只有設定 FIRESTORE_EMULATOR_HOST 與 FIREBASE_AUTH_EMULATOR_HOST 時才執行，平常略過。
執行方式見 README.md「測試」。不會連到任何線上專案。
"""

import hashlib
import io
import json
import os
import re
import tempfile
import unittest
import urllib.request
from pathlib import Path

import admin_notice_tool as tool
import firebase_rest as fb
import notice_format as nf

FIRESTORE_HOST = os.environ.get(fb.FIRESTORE_EMULATOR_ENV)
AUTH_HOST = os.environ.get(fb.AUTH_EMULATOR_ENV)
PROJECT = "demo-cares"
TEST_SEED = hashlib.sha256(b"cares-admin-notice-test/admin").digest()
TEST_PUBLIC_HEX = "10f835a2f82b877a2c1c705ef3c71d3640a40b4e39f6ca4197c17eaefb05a176"
PASSWORD = "emulator-only-password"


def request(method: str, url: str, body=None, token=None) -> dict:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=headers)) as r:
        return json.loads(r.read() or b"{}")


def documents_url(path: str = "") -> str:
    return f"http://{FIRESTORE_HOST}/v1/projects/{PROJECT}/databases/(default)/documents{path}"


def sign_up(email: str) -> str:
    response = request("POST", f"http://{AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=any",
                       {"email": email, "password": PASSWORD, "returnSecureToken": True})
    return response["localId"]


def read_as_owner(path: str):
    """以 emulator 的 owner 身分讀，繞過 rules；文件不存在回傳 None。"""
    try:
        return request("GET", documents_url(f"/{path}"), token="owner")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


@unittest.skipUnless(FIRESTORE_HOST and AUTH_HOST, "需要 Firestore 與 Auth emulator")
class SendThroughEmulatorTest(unittest.TestCase):
    def setUp(self):
        request("DELETE", documents_url().replace("/v1/", "/emulator/v1/"))
        request("DELETE", f"http://{AUTH_HOST}/emulator/v1/projects/{PROJECT}/accounts")
        self.admin_uid = sign_up("admin@example.org")
        self.member_uid = sign_up("member@example.org")
        # Administrator 只能由後台授予：以 owner 身分建立 admins/{uid}
        fb.commit(fb.urllib_post, fb.Endpoints.from_env(os.environ), PROJECT, "owner",
                  [fb.create_write(PROJECT, f"admins/{self.admin_uid}", {"grantedBy": "emulator test"})])

        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp))
        self.key_path = tmp / "admin-ed25519-01.key"
        self.key_path.write_text(TEST_SEED.hex() + "\n")
        os.chmod(self.key_path, 0o600)
        self.public_keys = tmp / "admin_public_keys.json"
        self.public_keys.write_text(json.dumps({"0x01": TEST_PUBLIC_HEX}))
        self.google_services = tmp / "google-services.json"
        self.google_services.write_text(json.dumps({
            "project_info": {"project_id": PROJECT},
            "client": [{"client_info": {"android_client_info": {"package_name": "com.bitchat.droid"}},
                        "api_key": [{"current_key": "emulator-api-key"}]}],
        }))
        self.stdout, self.stderr = io.StringIO(), io.StringIO()

    def send(self, email: str) -> int:
        return tool.main(
            ["send", "--email", email, "--level", "urgent", "--content", "土石流警戒：請立即撤離",
             "--valid-for", "6h", "--key", str(self.key_path), "--yes"],
            tool.Deps(stdout=self.stdout, stderr=self.stderr,
                      env={**os.environ, tool.PASSWORD_ENV: PASSWORD},
                      public_keys_path=self.public_keys, google_services_path=self.google_services))

    def test_administrator_writes_notice_and_record_through_the_rules(self):
        self.assertEqual(0, self.send("admin@example.org"), self.stderr.getvalue())

        message_id = re.search(r"admin_notices/([0-9a-f]{16})", self.stdout.getvalue()).group(1)
        notice = read_as_owner(f"admin_notices/{message_id}")["fields"]
        self.assertEqual({"wire", "expiresAt", "createdAt", "createdBy"}, set(notice))
        self.assertEqual(self.admin_uid, notice["createdBy"]["stringValue"])
        wire = __import__("base64").b64decode(notice["wire"]["bytesValue"])
        nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), wire)
        self.assertEqual(message_id, wire[4:12].hex())

        record = read_as_owner(f"admin_notice_records/{message_id}")["fields"]
        self.assertEqual("土石流警戒：請立即撤離", record["content"]["stringValue"])
        self.assertEqual(self.admin_uid, record["createdBy"]["stringValue"])
        self.assertIn("timestampValue", record["createdAt"])

    def test_account_that_is_not_an_administrator_writes_nothing(self):
        self.assertNotEqual(0, self.send("member@example.org"))

        self.assertIn("PERMISSION_DENIED", self.stderr.getvalue())
        self.assertEqual({}, request("GET", documents_url("/admin_notices"), token="owner"))
        self.assertEqual({}, request("GET", documents_url("/admin_notice_records"), token="owner"))


if __name__ == "__main__":
    unittest.main()
