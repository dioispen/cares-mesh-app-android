#!/usr/bin/env python3
"""Admin Notice 的開發用發送工具（docs/ADMIN_NOTICE_V1.md，操作手冊見同目錄 README.md）。

  keygen  產生管理端 Ed25519 金鑰對：私鑰寫進權限 0600 的檔案，只印出公鑰。
  send    以 Administrator 帳號登入，把簽好章的廣播公告寫進 Firestore。

需要 `pip install cryptography`。其他只用標準函式庫。
"""

import argparse
import getpass
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping, TextIO

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import firebase_rest as fb
import notice_format as nf

HERE = Path(__file__).resolve().parent
DEFAULT_KEY_DIR = Path.home() / ".config" / "cares-mesh" / "admin-notice"
PUBLIC_KEYS_PATH = HERE / "admin_public_keys.json"
GOOGLE_SERVICES_PATH = HERE.parents[1] / "app" / "google-services.json"
PASSWORD_ENV = "CARES_ADMIN_PASSWORD"

LEVEL_NAMES = {"info": nf.LEVEL_INFO, "important": nf.LEVEL_IMPORTANT, "urgent": nf.LEVEL_URGENT}
LEVEL_LABELS = {nf.LEVEL_INFO: "資訊", nf.LEVEL_IMPORTANT: "重要", nf.LEVEL_URGENT: "緊急"}
KIND_NAMES = {nf.KIND_BROADCAST: "broadcast", nf.KIND_TARGETED: "targeted"}


def default_key_path(key_id: int) -> Path:
    return DEFAULT_KEY_DIR / f"admin-ed25519-{key_id:02x}.key"


@dataclass
class Deps:
    """命令列以外的輸入與輸出。測試換成假的，正式執行用預設值。"""
    stdout: TextIO = field(default_factory=lambda: sys.stdout)
    stderr: TextIO = field(default_factory=lambda: sys.stderr)
    env: Mapping[str, str] = field(default_factory=lambda: os.environ)
    post: Callable[[str, dict, dict], dict] = fb.urllib_post
    now_ms: Callable[[], int] = lambda: time.time_ns() // 1_000_000
    getpass: Callable[[str], str] = getpass.getpass
    input: Callable[[str], str] = input
    public_keys_path: Path = PUBLIC_KEYS_PATH
    google_services_path: Path = GOOGLE_SERVICES_PATH


class ToolError(Exception):
    """要告訴操作者、並以非 0 結束的錯誤。"""


# ---- 私鑰檔 ----------------------------------------------------------------
#
# 格式：一行 64 個小寫十六進位字元，是 Ed25519 的 32 bytes seed（RFC 8032 的 private key）。
# 管理後台用純 Dart 載入時最簡單，例如 package:cryptography 的 newKeyPairFromSeed。

SEED_HEX = re.compile(r"^[0-9a-f]{64}$")


def load_private_key(path: Path) -> Ed25519PrivateKey:
    try:
        text = Path(path).read_text(encoding="ascii").strip()
    except FileNotFoundError:
        raise ToolError(f"找不到私鑰檔 {path}") from None
    if not SEED_HEX.match(text):
        raise ToolError(f"{path} 不是私鑰檔：應該是一行 64 個小寫十六進位字元")
    return Ed25519PrivateKey.from_private_bytes(bytes.fromhex(text))


def write_new_private_key(path: Path, key: Ed25519PrivateKey):
    """只建立新檔，已經存在就丟 FileExistsError；不會覆寫任何既有的私鑰。

    途中新建的每一層目錄都是 0700（os.makedirs 只把 mode 套在最後一層）。
    """
    missing = [d for d in [path.parent, *path.parent.parents] if not d.exists()]
    for d in reversed(missing):
        os.mkdir(d, 0o700)
        os.chmod(d, 0o700)  # 不受 umask 影響
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(fd, 0o600)
        os.write(fd, (nf.raw_private(key).hex() + "\n").encode("ascii"))
    finally:
        os.close(fd)


def cmd_keygen(args, deps: Deps) -> int:
    path = Path(args.out) if args.out else default_key_path(args.key_id)
    key = Ed25519PrivateKey.generate()
    try:
        write_new_private_key(path, key)
    except FileExistsError:
        raise ToolError(f"{path} 已經存在，不會覆寫。換 key 時用新的 keyId（--key-id）") from None
    deps.stderr.write(f"私鑰已寫入 {path}（權限 0600）。公鑰（keyId 0x{args.key_id:02x}）：\n")
    deps.stdout.write(nf.raw_public(key).hex() + "\n")
    return 0


# ---- 發送 ------------------------------------------------------------------

def load_public_keys(path: Path) -> dict[int, bytes]:
    """App 內建的 keyId → 公鑰對照表（admin_public_keys.json）。"""
    table = json.loads(Path(path).read_text(encoding="utf-8"))
    return {int(key_id, 16): bytes.fromhex(public) for key_id, public in table.items()}


def check_signed_by_published_key(wire: bytes, key_id: int, public_keys_path: Path):
    """寫進 Firestore 之前，用 App 內建的那把公鑰驗一次：選錯私鑰檔的公告，App 會全部丟掉。"""
    public = load_public_keys(public_keys_path).get(key_id)
    if public is None:
        raise ToolError(f"keyId 0x{key_id:02x} 沒有登記在 {public_keys_path.name}，App 不認得這把 key")
    try:
        nf.verify(public, wire)
    except InvalidSignature:
        raise ToolError(f"私鑰檔與 {public_keys_path.name} 登記的 keyId 0x{key_id:02x} 公鑰不符") from None


def notice_writes(project_id: str, *, message_id: bytes, wire: bytes, record: dict, uid: str) -> list:
    """admin_notices 與 admin_notice_records 各一份，欄位見 docs/ADMIN_NOTICE_V1.md「Firestore」。"""
    doc_id = message_id.hex()
    expires_at = int.from_bytes(wire[20:28], "big")  # 與 wire 裡簽過的 expiresAt 一致
    notice = {"wire": wire, "expiresAt": fb.Timestamp(expires_at), "createdBy": uid}
    return [
        fb.create_write(project_id, f"admin_notices/{doc_id}", notice, server_time_fields=["createdAt"]),
        fb.create_write(project_id, f"admin_notice_records/{doc_id}", {**record, "createdBy": uid},
                        server_time_fields=["createdAt"]),
    ]


def broadcast_record(*, level: int, content: str, issued_at: int, expires_at: int,
                     replaces: bytes, batch_id: bytes) -> dict:
    """admin_notice_records 的明文留存（操作者 createdBy 由 notice_writes 補上）。"""
    return {
        "kind": KIND_NAMES[nf.KIND_BROADCAST],
        "level": {v: k for k, v in LEVEL_NAMES.items()}[level],
        "content": content,
        "issuedAt": fb.Timestamp(issued_at),
        "expiresAt": fb.Timestamp(expires_at),
        "replaces": None if replaces == nf.NO_REPLACES else replaces.hex(),
        "batchId": batch_id.hex(),
    }


DURATION = re.compile(r"^(?:(\d+)h)?(?:(\d+)m)?$")


def duration_ms(text: str) -> int:
    """「6h」「90m」「1h30m」轉成毫秒。"""
    match = DURATION.match(text)
    if not text or not match:
        raise argparse.ArgumentTypeError("有效期的寫法是 6h、90m 或 1h30m")
    hours, minutes = (int(g or 0) for g in match.groups())
    return (hours * 60 + minutes) * 60_000


def local_time(epoch_ms: int) -> str:
    return datetime.fromtimestamp(epoch_ms / 1000, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def cmd_send(args, deps: Deps) -> int:
    try:
        endpoints = fb.Endpoints.from_env(deps.env)
    except ValueError as e:
        raise ToolError(str(e)) from None
    project_id, api_key = fb.load_app_config(deps.google_services_path)
    project_id = args.project or project_id

    key = load_private_key(Path(args.key) if args.key else default_key_path(args.key_id))
    level = LEVEL_NAMES[args.level]
    issued_at = deps.now_ms()
    expires_at = issued_at + args.valid_for
    message_id = nf.new_message_id()
    try:
        wire = nf.build_broadcast(key, key_id=args.key_id, level=level, message_id=message_id,
                                  issued_at=issued_at, expires_at=expires_at, content=args.content)
    except nf.NoticeError as e:
        raise ToolError(str(e)) from None
    check_signed_by_published_key(wire, args.key_id, deps.public_keys_path)

    out = deps.stdout
    out.write("Admin Notice（廣播）\n"
              f"  等級       {LEVEL_LABELS[level]}（{args.level}）\n"
              f"  內容       {len(args.content.encode('utf-8'))} bytes：{args.content}\n"
              f"  messageId  {message_id.hex()}\n"
              f"  發出       {local_time(issued_at)}\n"
              f"  到期       {local_time(expires_at)}\n"
              f"  寫入       {'emulator' if endpoints.emulated else '正式環境'}的 Firestore（{project_id}）\n")
    if args.dry_run:
        out.write(f"wire（{len(wire)} bytes）：{wire.hex()}\n--dry-run：沒有登入，也沒有寫入。\n")
        return 0
    if not args.yes:
        out.write("實地實驗進行中不要發公告（見 README.md）。這則公告會送到所有裝置，送出後收不回來，只能再發撤回。\n")
        if deps.input("確定送出？輸入 yes 送出：").strip() != "yes":
            out.write("沒有送出。\n")
            return 1

    password = deps.env.get(PASSWORD_ENV) or deps.getpass(f"{args.email} 的密碼：")
    try:
        id_token, uid = fb.sign_in_with_password(deps.post, endpoints, api_key, args.email, password)
    except fb.FirebaseError as e:
        raise ToolError(f"登入失敗：{e}") from None

    record = broadcast_record(level=level, content=args.content, issued_at=issued_at,
                              expires_at=expires_at, replaces=nf.NO_REPLACES, batch_id=message_id)
    writes = notice_writes(project_id, message_id=message_id, wire=wire, record=record, uid=uid)
    try:
        fb.commit(deps.post, endpoints, project_id, id_token, writes)
    except fb.FirebaseError as e:
        raise ToolError(f"寫入失敗：{e}{commit_hint(e)}") from None
    out.write(f"已寫入 admin_notices/{message_id.hex()} 與 admin_notice_records/{message_id.hex()}。\n")
    return 0


def commit_hint(error: fb.FirebaseError) -> str:
    if error.code == "PERMISSION_DENIED":
        return "\n被 security rules 擋下：這個帳號是 Administrator 嗎（admins/{uid} 要存在）？"
    if error.code in ("ALREADY_EXISTS", "FAILED_PRECONDITION"):
        return "\nmessageId 撞號，什麼都沒有寫入；重新執行即可，會換一個 messageId。"
    return ""


# ---- 命令列 ----------------------------------------------------------------

def key_id_arg(text: str) -> int:
    value = int(text, 0)
    if not 0x01 <= value <= 0xFF:
        raise argparse.ArgumentTypeError("keyId 只能是 1–255，0x00 保留不用")
    return value


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="admin_notice_tool.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    keygen = sub.add_parser("keygen", help="產生管理端 Ed25519 金鑰對，只印出公鑰")
    keygen.add_argument("--key-id", type=key_id_arg, default=0x01, help="金鑰的 keyId，預設 0x01")
    keygen.add_argument("--out", help="私鑰檔路徑，預設 ~/.config/cares-mesh/admin-notice/admin-ed25519-<keyId>.key")
    keygen.set_defaults(run=cmd_keygen)

    send = sub.add_parser("send", help="發一則廣播公告",
                          description=f"密碼從環境變數 {PASSWORD_ENV} 讀取，沒有設定就在終端機詢問；不接受命令列參數。")
    send.add_argument("--email", required=True, help="Administrator 帳號的 email")
    send.add_argument("--level", required=True, choices=list(LEVEL_NAMES), help="資訊、重要或緊急")
    send.add_argument("--content", required=True, help="公告內容，UTF-8 最多 300 bytes（約 100 個中文字）")
    send.add_argument("--valid-for", required=True, type=duration_ms, metavar="DURATION",
                      help="有效期，例如 6h、90m、1h30m，最長 24h")
    send.add_argument("--key-id", type=key_id_arg, default=0x01, help="私鑰的 keyId，預設 0x01")
    send.add_argument("--key", help="私鑰檔路徑，預設 ~/.config/cares-mesh/admin-notice/admin-ed25519-<keyId>.key")
    send.add_argument("--project", help="Firestore 專案，預設讀 app/google-services.json")
    send.add_argument("--yes", action="store_true", help="不詢問，直接送出")
    send.add_argument("--dry-run", action="store_true", help="只組包、簽章並印出，不登入也不寫入")
    send.set_defaults(run=cmd_send)
    return p


def main(argv=None, deps: Deps = None) -> int:
    deps = deps or Deps()
    args = parser().parse_args(argv)
    try:
        return args.run(args, deps)
    except ToolError as e:
        deps.stderr.write(f"錯誤：{e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
