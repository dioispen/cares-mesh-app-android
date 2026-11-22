"""send 對著 Firebase emulator 跑一次：REST 查詢與 commit 真的經過 firestore.rules。

只有設定 FIRESTORE_EMULATOR_HOST 與 FIREBASE_AUTH_EMULATOR_HOST 時才執行，平常略過。
執行方式見 README.md「測試」。不會連到任何線上專案。
"""

import base64
import hashlib
import io
import json
import os
import re
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

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
class EmulatorTestCase(unittest.TestCase):
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


class SendThroughEmulatorTest(EmulatorTestCase):
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


DAY_MS = 24 * 3_600_000
TARGETED_CONTENT = "救援人員約 10 分鐘內抵達，請留在原地"


def sign_in(email: str) -> str:
    """emulator 帳號的 ID token，用來以本人身分經過 rules 寫入。"""
    response = request("POST", f"http://{AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=any",
                       {"email": email, "password": PASSWORD, "returnSecureToken": True})
    return response["idToken"]


class SendTargetedThroughEmulatorTest(EmulatorTestCase):
    """定向公告：查詢 installations 與寫入都經過 firestore.rules，寫出的 wire 只有收件裝置解得開。"""

    def setUp(self):
        super().setUp()
        self.endpoints = fb.Endpoints.from_env(os.environ)
        self.member_token = sign_in("member@example.org")

    def register(self, uid: str, handle: str, *, token=None, registered_at=None) -> X25519PrivateKey:
        """登記一台裝置。token 是本人時照 App 的做法經過 rules、registeredAt 用伺服器時間；
        沒有 token 時以 owner 繞過 rules，才能填過去的 registeredAt。"""
        key = X25519PrivateKey.generate()
        fields = {"reporterHandle": handle, "signingPublicKey": bytes(32), "noticePublicKey": nf.raw_public(key)}
        path = f"reporter_handles/{uid}/installations/{handle}"
        if token:
            write = fb.create_write(PROJECT, path, fields, server_time_fields=["registeredAt"])
        else:
            write = fb.create_write(PROJECT, path, {**fields, "registeredAt": fb.Timestamp(registered_at)})
        fb.commit(fb.urllib_post, self.endpoints, PROJECT, token or "owner", [write])
        return key

    def send(self, *targets, email="admin@example.org") -> int:
        return tool.main(
            ["send", "--email", email, "--level", "important", "--content", TARGETED_CONTENT,
             "--valid-for", "2h", "--key", str(self.key_path), "--yes", *targets],
            tool.Deps(stdout=self.stdout, stderr=self.stderr,
                      env={**os.environ, tool.PASSWORD_ENV: PASSWORD},
                      public_keys_path=self.public_keys, google_services_path=self.google_services))

    def written(self) -> list[tuple[str, bytes, dict]]:
        """這次寫入的每一則：(messageId, wire, admin_notice_records 的欄位)。"""
        notices = []
        for message_id in re.findall(r"admin_notices/([0-9a-f]{16})", self.stdout.getvalue()):
            notice = read_as_owner(f"admin_notices/{message_id}")["fields"]
            wire = base64.b64decode(notice["wire"]["bytesValue"])
            nf.verify(bytes.fromhex(TEST_PUBLIC_HEX), wire)
            record = read_as_owner(f"admin_notice_records/{message_id}")["fields"]
            notices.append((message_id, wire, {k: fb.decode_value(v) for k, v in record.items()}))
        return notices

    @staticmethod
    def opens(wire: bytes, key: X25519PrivateKey) -> bool:
        return nf.open_as_recipient(wire, key) == TARGETED_CONTENT.encode()

    def test_by_uid_every_device_the_member_registered_opens_the_notice(self):
        phone = self.register(self.member_uid, "a1a1a1a1a1a1", token=self.member_token)
        tablet = self.register(self.member_uid, "a2a2a2a2a2a2", token=self.member_token)
        stranger = X25519PrivateKey.generate()

        self.assertEqual(0, self.send("--uid", self.member_uid), self.stderr.getvalue())

        (message_id, wire, record), = self.written()
        self.assertEqual(nf.KIND_TARGETED, wire[1])
        self.assertEqual([True, True, False], [self.opens(wire, k) for k in (phone, tablet, stranger)])
        self.assertEqual("targeted", record["kind"])
        self.assertEqual(message_id, record["batchId"])
        self.assertEqual([self.member_uid], record["recipientUids"])
        self.assertEqual(2, record["recipientCount"])
        self.assertEqual({"a1a1a1a1a1a1", "a2a2a2a2a2a2"}, {d["reporterHandle"] for d in record["recipientDevices"]})

    def test_by_handle_the_newest_registration_opens_the_notice_and_the_operator_is_warned(self):
        # 同一個 Handle 先登記在另一個帳號底下（兩天前），後來 member 以 App 登記（現在）。
        earlier = self.register("uid-someone-else", "c1c1c1c1c1c1", registered_at=int(time.time() * 1000) - 2 * DAY_MS)
        newest = self.register(self.member_uid, "c1c1c1c1c1c1", token=self.member_token)

        self.assertEqual(0, self.send("--handle", "c1c1c1c1c1c1"), self.stderr.getvalue())

        (_, wire, record), = self.written()
        self.assertEqual([True, False], [self.opens(wire, k) for k in (newest, earlier)])
        self.assertEqual(["c1c1c1c1c1c1"], record["recipientHandles"])
        self.assertIn("uid-someone-else", self.stderr.getvalue())
        self.assertIn("冒領", self.stderr.getvalue())

    def test_six_devices_are_split_into_two_notices_sharing_one_batch_id(self):
        keys = [self.register(self.member_uid, f"d{i}d{i}d{i}d{i}d{i}d{i}", token=self.member_token) for i in range(6)]

        self.assertEqual(0, self.send("--uid", self.member_uid), self.stderr.getvalue())

        notices = self.written()
        self.assertEqual(2, len(notices))
        self.assertEqual(1, len({record["batchId"] for _, _, record in notices}))
        self.assertIn(notices[0][2]["batchId"], {message_id for message_id, _, _ in notices})
        self.assertEqual([1] * 6, [sum(self.opens(wire, k) for _, wire, _ in notices) for k in keys])

    def test_a_target_without_recipient_devices_writes_nothing(self):
        self.register(self.member_uid, "a1a1a1a1a1a1", token=self.member_token)

        self.assertNotEqual(0, self.send("--uid", self.member_uid, "--uid", "uid-nobody"))

        self.assertIn("uid-nobody", self.stderr.getvalue())
        self.assertEqual({}, request("GET", documents_url("/admin_notices"), token="owner"))

    def test_an_account_that_is_not_an_administrator_cannot_look_recipients_up(self):
        self.register(self.admin_uid, "e1e1e1e1e1e1", registered_at=int(time.time() * 1000))

        self.assertNotEqual(0, self.send("--uid", self.admin_uid, email="member@example.org"))

        self.assertIn("PERMISSION_DENIED", self.stderr.getvalue())
        self.assertEqual({}, request("GET", documents_url("/admin_notices"), token="owner"))


if __name__ == "__main__":
    unittest.main()
