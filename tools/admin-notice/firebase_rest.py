"""以 Firebase Auth 與 Firestore 的 REST API 寫入，只用標準函式庫。

刻意不用 service account 或 firebase-admin：用 Administrator 帳號的 ID token 寫入，
Firestore security rules 才會套用，與管理後台走同一條路（docs/ADMIN_NOTICE_V1.md「Firestore」）。

設定 FIRESTORE_EMULATOR_HOST 與 FIREBASE_AUTH_EMULATOR_HOST 時改連 emulator（兩個要一起設）。
"""

import base64
import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

FIRESTORE_EMULATOR_ENV = "FIRESTORE_EMULATOR_HOST"
AUTH_EMULATOR_ENV = "FIREBASE_AUTH_EMULATOR_HOST"
ANDROID_PACKAGE = "com.bitchat.droid"


class FirebaseError(Exception):
    """Firebase 回了錯誤。status 是 HTTP 狀態碼，code 是錯誤代碼（例如 PERMISSION_DENIED）。"""

    def __init__(self, status: int, code: str, message: str):
        super().__init__(f"HTTP {status} {code}: {message}")
        self.status, self.code, self.message = status, code, message


@dataclass(frozen=True)
class Endpoints:
    auth: str       # 到 identitytoolkit.googleapis.com 為止
    firestore: str  # /v1/ 之前的部分
    emulated: bool

    @staticmethod
    def from_env(env) -> "Endpoints":
        firestore_host = env.get(FIRESTORE_EMULATOR_ENV)
        auth_host = env.get(AUTH_EMULATOR_ENV)
        if bool(firestore_host) != bool(auth_host):
            # 只設一個的話，emulator 的 token 會送到正式的 Firestore，或反過來。
            raise ValueError(f"{FIRESTORE_EMULATOR_ENV} 與 {AUTH_EMULATOR_ENV} 要一起設定或一起不設")
        if firestore_host:
            return Endpoints(auth=f"http://{auth_host}/identitytoolkit.googleapis.com",
                             firestore=f"http://{firestore_host}", emulated=True)
        return Endpoints(auth="https://identitytoolkit.googleapis.com",
                         firestore="https://firestore.googleapis.com", emulated=False)


def load_app_config(google_services_path: Path) -> tuple[str, str]:
    """從 App 的 google-services.json 讀出 (project_id, Web API key)。"""
    config = json.loads(Path(google_services_path).read_text(encoding="utf-8"))
    project_id = config["project_info"]["project_id"]
    for client in config["client"]:
        if client["client_info"]["android_client_info"]["package_name"] == ANDROID_PACKAGE:
            return project_id, client["api_key"][0]["current_key"]
    raise ValueError(f"{google_services_path} 裡沒有 {ANDROID_PACKAGE} 的設定")


def urllib_post(url: str, body: dict, headers: dict) -> dict:
    """POST JSON、回傳 JSON；錯誤轉成 FirebaseError。"""
    request = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as e:
        with e:
            raw = e.read()
        try:
            error = json.loads(raw).get("error", {})
        except ValueError:
            error = {}
        raise FirebaseError(e.code, error.get("status") or error.get("message", ""),
                            error.get("message", e.reason)) from None


def sign_in_with_password(post, endpoints: Endpoints, api_key: str, email: str, password: str):
    """以 email 與密碼登入，回傳 (ID token, uid)。"""
    response = post(f"{endpoints.auth}/v1/accounts:signInWithPassword?key={api_key}",
                    {"email": email, "password": password, "returnSecureToken": True}, {})
    return response["idToken"], response["localId"]


# ---- Firestore 文件 ----------------------------------------------------------

class Timestamp:
    """Firestore 的 timestamp 欄位，精度到毫秒。"""

    def __init__(self, epoch_ms: int):
        self.epoch_ms = epoch_ms

    def rfc3339(self) -> str:
        t = datetime.fromtimestamp(self.epoch_ms / 1000, tz=timezone.utc)
        return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{self.epoch_ms % 1000:03d}Z"


def encode_value(value) -> dict:
    if value is None:
        return {"nullValue": None}
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        return {"integerValue": str(value)}
    if isinstance(value, str):
        return {"stringValue": value}
    if isinstance(value, bytes):
        return {"bytesValue": base64.b64encode(value).decode("ascii")}
    if isinstance(value, Timestamp):
        return {"timestampValue": value.rfc3339()}
    raise TypeError(f"不支援的欄位型別 {type(value).__name__}")


def document_name(project_id: str, path: str) -> str:
    return f"projects/{project_id}/databases/(default)/documents/{path}"


def create_write(project_id: str, path: str, fields: dict, server_time_fields=()) -> dict:
    """只建立、不覆寫的 write：文件已經存在時整個 commit 失敗。

    server_time_fields 填伺服器時間（等同 SDK 的 serverTimestamp()），rules 看到的會是
    request.time。
    """
    return {
        "update": {"name": document_name(project_id, path),
                   "fields": {k: encode_value(v) for k, v in fields.items()}},
        "updateTransforms": [{"fieldPath": f, "setToServerValue": "REQUEST_TIME"}
                             for f in server_time_fields],
        "currentDocument": {"exists": False},
    }


def commit(post, endpoints: Endpoints, project_id: str, id_token: str, writes: list) -> dict:
    """一次 commit 寫入所有 writes：全部成功或全部失敗，每份文件都經過 security rules。"""
    return post(f"{endpoints.firestore}/v1/projects/{project_id}/databases/(default)/documents:commit",
                {"writes": writes}, {"Authorization": f"Bearer {id_token}"})
