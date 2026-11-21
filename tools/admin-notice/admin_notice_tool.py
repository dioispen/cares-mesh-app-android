#!/usr/bin/env python3
"""Admin Notice 的開發用發送工具（docs/ADMIN_NOTICE_V1.md，操作手冊見同目錄 README.md）。

  keygen  產生管理端 Ed25519 金鑰對：私鑰寫進權限 0600 的檔案，只印出公鑰。
  send    以 Administrator 帳號登入，把簽好章的公告寫進 Firestore：廣播，或以 --uid、
          --handle 指定收件對象的定向公告（加密給收件裝置，超過 5 台拆成同一個 batchId 的多則）。
          加上 --replaces 就是更正一則已發出的公告。
  revoke  撤回一則公告，或以 --batch 撤回整批：每一則各發一則純撤回（廣播 kind、空 body）。

需要 `pip install cryptography`。其他只用標準函式庫。
"""

from __future__ import annotations

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


def check_key_is_published(key: Ed25519PrivateKey, key_id: int, public_keys_path: Path):
    """同 check_signed_by_published_key，但在還沒有 wire 時就能檢查（定向公告要先登入才組得出來）。"""
    public = load_public_keys(public_keys_path).get(key_id)
    if public is None:
        raise ToolError(f"keyId 0x{key_id:02x} 沒有登記在 {public_keys_path.name}，App 不認得這把 key")
    if nf.raw_public(key) != public:
        raise ToolError(f"私鑰檔與 {public_keys_path.name} 登記的 keyId 0x{key_id:02x} 公鑰不符")


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


def notice_record(*, kind: int, level: int, content: str, issued_at: int, expires_at: int,
                  replaces: bytes, batch_id: bytes) -> dict:
    """admin_notice_records 的明文留存（操作者 createdBy 由 notice_writes 補上）。"""
    return {
        "kind": KIND_NAMES[kind],
        "level": {v: k for k, v in LEVEL_NAMES.items()}[level],
        "content": content,
        "issuedAt": fb.Timestamp(issued_at),
        "expiresAt": fb.Timestamp(expires_at),
        "replaces": None if replaces == nf.NO_REPLACES else replaces.hex(),
        "batchId": batch_id.hex(),
    }


def targeted_record(*, level: int, content: str, issued_at: int, expires_at: int, batch_id: bytes,
                    uids: list, handles: list, devices: list, replaces: bytes = nf.NO_REPLACES) -> dict:
    """定向公告的留存：notice_record 加上收件對象（docs/ADMIN_NOTICE_V1.md「Firestore」）。

    recipientUids、recipientHandles 是操作者指定的收件對象，同一批的每一則都一樣；
    recipientCount 與 recipientDevices 是這一則實際加密給的收件裝置。
    """
    return {
        **notice_record(kind=nf.KIND_TARGETED, level=level, content=content, issued_at=issued_at,
                        expires_at=expires_at, replaces=replaces, batch_id=batch_id),
        "recipientUids": list(uids),
        "recipientHandles": list(handles),
        "recipientCount": len(devices),
        "recipientDevices": [{"uid": d.uid, "reporterHandle": d.handle, "noticePublicKey": d.notice_public_key}
                             for d in devices],
    }


# ---- 收件裝置（docs/ADMIN_NOTICE_V1.md「給管理後台的介面契約」第 2 步）--------------

STALE_REGISTRATION_MS = 30 * 24 * 3600_000
INSTALLATION_PATH = re.compile(r"^reporter_handles/([^/]+)/installations/([^/]+)$")


@dataclass(frozen=True)
class Installation:
    """reporter_handles/{uid}/installations/{handle} 的一份登記：一支手機上的一次登入。"""
    uid: str
    handle: str
    notice_public_key: bytes | None  # None：舊版 App 寫的登記，收不到定向公告
    registered_at_ms: int | None


def as_installation(path: str, fields: dict) -> Installation | None:
    match = INSTALLATION_PATH.match(path)
    if not match:
        return None  # collection group 查詢也會找到別的路徑下名為 installations 的文件
    key = fields.get("noticePublicKey")
    registered = fields.get("registeredAt")
    return Installation(
        uid=match.group(1), handle=match.group(2),
        notice_public_key=key if isinstance(key, bytes) and len(key) == nf.RECIPIENT_KEY_SIZE else None,
        registered_at_ms=registered.epoch_ms if isinstance(registered, fb.Timestamp) else None)


def installations_of(query, uid: str) -> list:
    """這個帳號登記過的每一台裝置。"""
    found = query(f"reporter_handles/{uid}", {"from": [{"collectionId": "installations"}]})
    return [i for i in (as_installation(path, fields) for path, fields in found) if i]


def installations_claiming(query, handle: str) -> list:
    """以 collection group 查詢宣稱這個 Reporter Handle 的每一份登記（MESH_GATEWAY.md 第 8 節）。"""
    found = query("", {
        "from": [{"collectionId": "installations", "allDescendants": True}],
        "where": {"fieldFilter": {"field": {"fieldPath": "reporterHandle"}, "op": "EQUAL",
                                  "value": {"stringValue": handle}}},
    })
    return [i for i in (as_installation(path, fields) for path, fields in found) if i and i.handle == handle]


def resolve_devices(query, *, uids: list, handles: list, now_ms: int, warn: Callable[[str], None]) -> list:
    """操作者指定的收件對象 → 收件裝置（每個 noticePublicKey 一台），依指定的順序、不重複。

    任何一個對象找不到收件裝置就丟 ToolError，一則都不送：送出去的公告收不回來，
    操作者應該先改正收件對象。
    """
    devices, unreachable = [], []
    for uid in uids:
        registered = installations_of(query, uid)
        reachable = [i for i in registered if i.notice_public_key]
        if not registered:
            unreachable.append(f"uid {uid}：沒有登記任何裝置（從未在有網路時登入過新版 App）")
        elif not reachable:
            unreachable.append(f"uid {uid}：登記的 {len(registered)} 台裝置都沒有 noticePublicKey（還沒更新的舊版 App）")
        devices += reachable
    for handle in handles:
        claims = installations_claiming(query, handle)
        if not claims:
            unreachable.append(f"Reporter Handle {handle}：沒有任何帳號登記過它")
            continue
        newest = max(claims, key=lambda i: i.registered_at_ms or 0)
        if len({c.uid for c in claims}) > 1:
            others = "、".join(f"{c.uid}（{when(c.registered_at_ms)}）" for c in claims if c is not newest)
            warn(f"Reporter Handle {handle} 有 {len(claims)} 個帳號宣稱：只加密給 registeredAt 最新的 "
                 f"{newest.uid}（{when(newest.registered_at_ms)}），不給 {others}。可能是同一支手機換過帳號，"
                 "也可能是冒領（docs/ADMIN_NOTICE_V1.md 已知限制 10）")
        if not newest.notice_public_key:
            unreachable.append(f"Reporter Handle {handle}：最新的登記（uid {newest.uid}）沒有 noticePublicKey"
                               "（還沒更新的舊版 App）")
            continue
        devices.append(newest)
    if unreachable:
        raise ToolError("找不到收件裝置，什麼都沒有送出：\n  " + "\n  ".join(unreachable))

    unique, seen = [], set()
    for d in devices:
        if d.notice_public_key not in seen:  # 同一台裝置以 uid 和 Handle 都指定到時只算一次
            seen.add(d.notice_public_key)
            unique.append(d)
    for d in unique:
        if d.registered_at_ms is None or now_ms - d.registered_at_ms > STALE_REGISTRATION_MS:
            warn(f"收件裝置 {d.uid}/{d.handle} 的登記超過 30 天（{when(d.registered_at_ms)}）：那支手機可能已經"
                 "換帳號、重裝或不再使用。照樣加密給它")
    return unique


def split_evenly(items: list, max_size: int) -> list:
    """拆成最少的幾份、每份不超過 max_size，大小盡量平均（6 → 3 + 3，不是 5 + 1）。

    收件裝置越少 payload 越小：4 個以內、內容 169 bytes 以內的公告不必切片（「大小上限」）。
    """
    count = -(-len(items) // max_size)
    size, extra = divmod(len(items), count)
    groups, start = [], 0
    for i in range(count):
        end = start + size + (1 if i < extra else 0)
        groups.append(items[start:end])
        start = end
    return groups


def when(epoch_ms: int | None) -> str:
    return "沒有 registeredAt" if epoch_ms is None else local_time(epoch_ms)


DURATION = re.compile(r"^(?:(\d+)h)?(?:(\d+)m)?$")


def duration_ms(text: str) -> int:
    """「6h」「90m」「1h30m」轉成毫秒。"""
    match = DURATION.match(text)
    if not text or not match:
        raise argparse.ArgumentTypeError("有效期的寫法是 6h、90m 或 1h30m")
    hours, minutes = (int(g or 0) for g in match.groups())
    return (hours * 60 + minutes) * 60_000


def duration_text(ms: int) -> str:
    """duration_ms 的反向，無條件進位到分鐘：5h、90m → 1h30m。"""
    minutes = -(-ms // 60_000)
    hours, minutes = divmod(minutes, 60)
    return (f"{hours}h" if hours else "") + (f"{minutes}m" if minutes or not hours else "")


def local_time(epoch_ms: int) -> str:
    return datetime.fromtimestamp(epoch_ms / 1000, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def connect(args, deps: Deps):
    """(endpoints, project_id, Web API key)：emulator 或正式環境，專案預設讀 google-services.json。"""
    try:
        endpoints = fb.Endpoints.from_env(deps.env)
    except ValueError as e:
        raise ToolError(str(e)) from None
    project_id, api_key = fb.load_app_config(deps.google_services_path)
    return endpoints, args.project or project_id, api_key


def sign_in(args, deps: Deps, endpoints, api_key) -> tuple[str, str]:
    """以 Administrator 帳號登入，回傳 (ID token, uid)。密碼從環境變數讀，沒有就在終端機詢問。"""
    password = deps.env.get(PASSWORD_ENV) or deps.getpass(f"{args.email} 的密碼：")
    try:
        return fb.sign_in_with_password(deps.post, endpoints, api_key, args.email, password)
    except fb.FirebaseError as e:
        raise ToolError(f"登入失敗：{e}") from None


def warner(deps: Deps) -> Callable[[str], None]:
    return lambda message: deps.stderr.write(f"警告：{message}\n")


def cmd_send(args, deps: Deps) -> int:
    endpoints, project_id, api_key = connect(args, deps)
    key = load_private_key(Path(args.key) if args.key else default_key_path(args.key_id))
    level = LEVEL_NAMES[args.level]
    issued_at = deps.now_ms()
    expires_at = issued_at + args.valid_for
    replaces = bytes.fromhex(args.replaces) if args.replaces else nf.NO_REPLACES
    if args.uid or args.handle:
        return send_targeted(args, deps, endpoints=endpoints, project_id=project_id, api_key=api_key,
                             key=key, level=level, issued_at=issued_at, expires_at=expires_at, replaces=replaces)
    message_id = nf.new_message_id()
    try:
        wire = nf.build_broadcast(key, key_id=args.key_id, level=level, message_id=message_id,
                                  issued_at=issued_at, expires_at=expires_at, content=args.content,
                                  replaces=replaces)
    except nf.NoticeError as e:
        raise ToolError(str(e)) from None
    check_signed_by_published_key(wire, args.key_id, deps.public_keys_path)

    session = original = None
    if args.replaces:
        # 被取代的那則只有 Administrator 讀得到，所以更正連 --dry-run 也要登入。
        session = sign_in(args, deps, endpoints, api_key)
        original = check_correction(Records(deps, endpoints, project_id, session[0]), args.replaces,
                                    issued_at=issued_at, expires_at=expires_at, targeted=False, warn=warner(deps))

    out = deps.stdout
    out.write(("Admin Notice（廣播）\n" if original is None else "Admin Notice（廣播，更正）\n")
              + (f"  取代       {original.describe()}\n" if original else "")
              + f"  等級       {LEVEL_LABELS[level]}（{args.level}）\n"
              f"  內容       {len(args.content.encode('utf-8'))} bytes：{args.content}\n"
              f"  messageId  {message_id.hex()}\n"
              f"  發出       {local_time(issued_at)}\n"
              f"  到期       {local_time(expires_at)}\n"
              f"  寫入       {'emulator' if endpoints.emulated else '正式環境'}的 Firestore（{project_id}）\n")
    if args.dry_run:
        done = "查過被取代的那則，沒有寫入。" if session else "沒有登入，也沒有寫入。"
        out.write(f"wire（{len(wire)} bytes）：{wire.hex()}\n--dry-run：{done}\n")
        return 0
    if not args.yes:
        out.write("實地實驗進行中不要發公告（見 README.md）。這則公告會送到所有裝置，送出後收不回來，只能再發撤回。\n")
        if deps.input("確定送出？輸入 yes 送出：").strip() != "yes":
            out.write("沒有送出。\n")
            return 1

    id_token, uid = session or sign_in(args, deps, endpoints, api_key)
    record = notice_record(kind=nf.KIND_BROADCAST, level=level, content=args.content, issued_at=issued_at,
                           expires_at=expires_at, replaces=replaces, batch_id=message_id)
    writes = notice_writes(project_id, message_id=message_id, wire=wire, record=record, uid=uid)
    try:
        fb.commit(deps.post, endpoints, project_id, id_token, writes)
    except fb.FirebaseError as e:
        raise ToolError(f"寫入失敗：{e}{commit_hint(e)}") from None
    out.write(f"已寫入 admin_notices/{message_id.hex()} 與 admin_notice_records/{message_id.hex()}。\n")
    return 0


def send_targeted(args, deps: Deps, *, endpoints, project_id, api_key, key, level, issued_at, expires_at,
                  replaces=nf.NO_REPLACES) -> int:
    """定向公告：查出收件裝置、每 5 台以內一則加密並簽章，一次 commit 寫入整批。

    更正（replaces）拆成多則時，每一則都帶同一個 replaces：每台裝置都會收到整批，先到的那則
    就把原公告標成已更正，App 再把連結移到它解得開的那則。
    """
    # App 會丟掉的公告與選錯的私鑰，在登入之前就擋下。
    try:
        nf.check_header_fields(key_id=args.key_id, level=level, message_id=nf.new_message_id(),
                               issued_at=issued_at, expires_at=expires_at, replaces=replaces)
        if not nf.encode_content(args.content):
            raise nf.NoticeError("定向公告的內容不能是空的")
    except nf.NoticeError as e:
        raise ToolError(str(e)) from None
    check_key_is_published(key, args.key_id, deps.public_keys_path)
    uids, handles = unique(args.uid), unique(args.handle)

    out = deps.stdout
    targets = [f"uid {u}" for u in uids] + [f"Reporter Handle {h}" for h in handles]
    out.write("Admin Notice（定向）\n"
              f"  等級       {LEVEL_LABELS[level]}（{args.level}）\n"
              f"  內容       {len(args.content.encode('utf-8'))} bytes：{args.content}\n"
              f"  收件對象   {'、'.join(targets)}\n"
              f"  發出       {local_time(issued_at)}\n"
              f"  到期       {local_time(expires_at)}\n"
              f"  寫入       {'emulator' if endpoints.emulated else '正式環境'}的 Firestore（{project_id}）\n")

    # 收件裝置的公鑰只有 Administrator 讀得到，所以 --dry-run 也要登入。
    id_token, uid = sign_in(args, deps, endpoints, api_key)
    if args.replaces:
        original = check_correction(Records(deps, endpoints, project_id, id_token), args.replaces,
                                    issued_at=issued_at, expires_at=expires_at, targeted=True, warn=warner(deps))
        out.write(f"  取代       {original.describe()}\n")

    def query(parent, structured_query):
        return fb.run_query(deps.post, endpoints, project_id, id_token, parent, structured_query)

    try:
        devices = resolve_devices(query, uids=uids, handles=handles, now_ms=issued_at,
                                  warn=lambda message: deps.stderr.write(f"警告：{message}\n"))
    except fb.FirebaseError as e:
        raise ToolError(f"查詢收件裝置失敗：{e}{query_hint(e)}") from None

    groups = split_evenly(devices, nf.MAX_RECIPIENTS)
    message_ids = []
    while len(message_ids) < len(groups):
        candidate = nf.new_message_id()
        if candidate not in message_ids:
            message_ids.append(candidate)
    batch_id = message_ids[0]  # 沒有拆的公告，batchId 就是自己的 messageId
    notices = []
    for message_id, group in zip(message_ids, groups):
        try:
            wire = nf.build_targeted(key, key_id=args.key_id, level=level, message_id=message_id,
                                     issued_at=issued_at, expires_at=expires_at, content=args.content,
                                     recipients=[d.notice_public_key for d in group], replaces=replaces)
        except nf.NoticeError as e:
            raise ToolError(f"{e}（收件裝置 {'、'.join(f'{d.uid}/{d.handle}' for d in group)}）") from None
        check_signed_by_published_key(wire, args.key_id, deps.public_keys_path)
        notices.append((message_id, group, wire))

    out.write(f"收件裝置   {len(devices)} 台"
              + (f"，超過 {nf.MAX_RECIPIENTS} 台，拆成 {len(groups)} 則（batchId {batch_id.hex()}）\n"
                 if len(groups) > 1 else "\n"))
    for message_id, group, _ in notices:
        out.write(f"  messageId {message_id.hex()}：{'、'.join(f'{d.uid}/{d.handle}' for d in group)}\n")
    if args.dry_run:
        for message_id, _, wire in notices:
            out.write(f"wire {message_id.hex()}（{len(wire)} bytes）：{wire.hex()}\n")
        out.write("--dry-run：查過收件裝置，沒有寫入。\n")
        return 0
    if not args.yes:
        out.write("實地實驗進行中不要發公告（見 README.md）。送出後收不回來，只能再發撤回。\n")
        if deps.input("確定送出？輸入 yes 送出：").strip() != "yes":
            out.write("沒有送出。\n")
            return 1

    writes = []
    for message_id, group, wire in notices:
        record = targeted_record(level=level, content=args.content, issued_at=issued_at, expires_at=expires_at,
                                 batch_id=batch_id, uids=uids, handles=handles, devices=group, replaces=replaces)
        writes += notice_writes(project_id, message_id=message_id, wire=wire, record=record, uid=uid)
    try:
        fb.commit(deps.post, endpoints, project_id, id_token, writes)
    except fb.FirebaseError as e:
        raise ToolError(f"寫入失敗：{e}{commit_hint(e)}") from None
    for message_id, _, _ in notices:
        out.write(f"已寫入 admin_notices/{message_id.hex()} 與 admin_notice_records/{message_id.hex()}。\n")
    return 0


# ---- 取代與撤回（docs/ADMIN_NOTICE_V1.md「撤回與取代」）------------------------------

RECORDS = "admin_notice_records"

# 純撤回至少保留這麼久：原公告已經或快要過期時，列表裡還留著它的手機（本機保留到過期後
# 7 天）也收得到撤回。
MIN_REVOKE_VALIDITY_MS = 3600_000


@dataclass(frozen=True)
class NoticeRecord:
    """admin_notice_records/{messageId} 讀回來的留存（欄位見 docs/ADMIN_NOTICE_V1.md「集合」）。"""
    message_id: str
    kind: str
    level: str
    content: str
    issued_at_ms: int
    expires_at_ms: int
    replaces: str | None
    batch_id: str

    @property
    def is_revoke(self) -> bool:
        """純撤回：廣播 kind、沒有內容、replaces 不為 null。"""
        return self.kind == KIND_NAMES[nf.KIND_BROADCAST] and not self.content and self.replaces is not None

    def describe(self) -> str:
        kind = "廣播" if self.kind == KIND_NAMES[nf.KIND_BROADCAST] else "定向"
        return (f"{self.message_id}（{kind}，{LEVEL_LABELS[LEVEL_NAMES[self.level]]}，"
                f"{local_time(self.expires_at_ms)} 到期）：{self.content}")


def as_notice_record(message_id: str, fields: dict) -> NoticeRecord:
    try:
        found = NoticeRecord(message_id=message_id, kind=fields["kind"], level=fields["level"],
                             content=fields["content"], issued_at_ms=fields["issuedAt"].epoch_ms,
                             expires_at_ms=fields["expiresAt"].epoch_ms, replaces=fields.get("replaces"),
                             batch_id=fields["batchId"])
    except (KeyError, AttributeError):
        found = None
    if found is None or found.kind not in KIND_NAMES.values() or found.level not in LEVEL_NAMES:
        raise ToolError(f"{RECORDS}/{message_id} 的欄位不完整或看不懂，無法檢查取代與撤回")
    return found


class Records:
    """以 Administrator 的身分讀 admin_notice_records：rules 只讓 Administrator 讀它。"""

    def __init__(self, deps: Deps, endpoints, project_id: str, id_token: str):
        self.deps, self.endpoints, self.project_id, self.id_token = deps, endpoints, project_id, id_token

    def get(self, message_id: str) -> NoticeRecord:
        try:
            (fields,) = fb.get_documents(self.deps.post, self.endpoints, self.project_id, self.id_token,
                                         [f"{RECORDS}/{message_id}"])
        except fb.FirebaseError as e:
            raise ToolError(f"讀取 {RECORDS}/{message_id} 失敗：{e}{query_hint(e)}") from None
        if fields is None:
            raise ToolError(f"找不到 {RECORDS}/{message_id}：messageId 打錯了，或不是發到這個專案的公告")
        return as_notice_record(message_id, fields)

    def where(self, field_path: str, value: str) -> list:
        """field_path == value 的每一則，依 messageId 排序。"""
        try:
            found = fb.run_query(self.deps.post, self.endpoints, self.project_id, self.id_token, "", {
                "from": [{"collectionId": RECORDS}],
                "where": {"fieldFilter": {"field": {"fieldPath": field_path}, "op": "EQUAL",
                                          "value": fb.encode_value(value)}},
            })
        except fb.FirebaseError as e:
            raise ToolError(f"查詢 {RECORDS} 失敗：{e}{query_hint(e)}") from None
        return sorted((as_notice_record(path.rsplit("/", 1)[1], fields) for path, fields in found),
                      key=lambda r: r.message_id)


def replace_problem(records: Records, original: NoticeRecord) -> str | None:
    """original 還能被取代或撤回嗎？可以就回傳 None。

    撤回本身不能：撤回它不會讓被撤回的那則回來。已經被取代過的也不能：App 上「已撤回」是
    最終狀態，「已更正」只連到一則新公告，要再改的是取代它的那一則。
    """
    if original.is_revoke:
        return f"{original.message_id} 本身是一則撤回（撤回 {original.replaces}），不能再取代或撤回"
    later = records.where("replaces", original.message_id)
    if not later:
        return None
    names = "、".join(r.message_id for r in later)
    if any(r.is_revoke for r in later):
        return f"{original.message_id} 已經撤回過了（{names}）"
    return f"{original.message_id} 已經被 {names} 更正；要再改，請取代或撤回 {names}"


def check_correction(records: Records, replaces: str, *, issued_at: int, expires_at: int, targeted: bool,
                     warn: Callable[[str], None]) -> NoticeRecord:
    """send --replaces 的所有檢查都在這裡，寫入之前、--dry-run 也做。回傳被取代的那則。

    - 被取代的那則要存在、還沒被取代過，而且不是撤回（replace_problem）。
    - 定向公告只能由定向公告更正，內容才會加密（「撤回與取代」）；廣播由定向公告更正時提醒操作者。
    - 新公告的 expiresAt 不早於被取代的那則，撤回紀錄才撐得到原公告過期。
    - 被取代的那則屬於拆成多則的批次時，提醒操作者其他則不受影響。
    """
    original = records.get(replaces)
    problem = replace_problem(records, original)
    if problem:
        raise ToolError(problem)
    if original.kind == KIND_NAMES[nf.KIND_TARGETED] and not targeted:
        raise ToolError(f"{replaces} 是定向公告：更正它的新公告也必須是定向的，內容才會加密。"
                        "請用 --uid 或 --handle 指定收件對象（通常與原公告相同），或改用 revoke 撤回")
    if original.kind == KIND_NAMES[nf.KIND_BROADCAST] and targeted:
        warn(f"{replaces} 是廣播，更正卻是定向公告：只有收件裝置看得到新內容，其他裝置只會看到原公告「已更正」")
    if expires_at < original.expires_at_ms:
        raise ToolError(f"新公告 {local_time(expires_at)} 到期，早於被取代的 {replaces}"
                        f"（{local_time(original.expires_at_ms)}）。新公告的 expiresAt 至少要等於被取代的那則，"
                        "撤回紀錄才撐得到原公告過期：至少要 "
                        f"--valid-for {duration_text(original.expires_at_ms - issued_at)}")
    siblings = [r.message_id for r in records.where("batchId", original.batch_id) if r.message_id != replaces]
    if siblings:
        warn(f"{replaces} 與 {'、'.join(siblings)} 是同一批（batchId {original.batch_id}），這次只更正 {replaces}，"
             f"其他則照舊有效、不會標成已更正。要整批收回，請用 revoke --batch {original.batch_id} 再重發")
    return original


def revoke_expiry(original: NoticeRecord, issued_at: int) -> int:
    """純撤回的 expiresAt：與原公告同時到期（附錄的 V3 與 V1 相同），撤回紀錄才撐得到原公告過期；
    原公告已經或快要過期時，至少保留 MIN_REVOKE_VALIDITY_MS。"""
    expires_at = max(original.expires_at_ms, issued_at + MIN_REVOKE_VALIDITY_MS)
    if expires_at > issued_at + nf.MAX_VALIDITY_MS:
        raise ToolError(f"{original.message_id} 要到 {local_time(original.expires_at_ms)} 才過期，超過現在起 24 小時的"
                        "有效期上限，撤回撐不到那時：發它的電腦時鐘是不是快了？")
    return expires_at


def cmd_revoke(args, deps: Deps) -> int:
    """純撤回（「撤回與取代」）：一律是廣播 kind、空 body，replaces 填被撤回的那則，不論它是廣播
    還是定向。--batch 撤回整批時每一則各發一則，一次 commit 寫入。不刪除任何 admin_notices 文件：
    公告已經進到 mesh，刪除文件不算撤回。"""
    endpoints, project_id, api_key = connect(args, deps)
    key = load_private_key(Path(args.key) if args.key else default_key_path(args.key_id))
    check_key_is_published(key, args.key_id, deps.public_keys_path)
    id_token, uid = sign_in(args, deps, endpoints, api_key)
    records = Records(deps, endpoints, project_id, id_token)
    warn = warner(deps)
    if args.batch:
        originals = records.where("batchId", args.batch)
        if not originals:
            raise ToolError(f"{RECORDS} 裡找不到 batchId {args.batch} 的公告")
    else:
        originals = [records.get(args.message_id)]

    issued_at = deps.now_ms()
    revokes, message_ids = [], set()
    for original in originals:
        problem = replace_problem(records, original)
        if problem:
            if not args.batch:
                raise ToolError(problem)
            warn(f"略過：{problem}")
            continue
        message_id = nf.new_message_id()
        while message_id in message_ids or message_id.hex() == original.message_id:
            message_id = nf.new_message_id()
        message_ids.add(message_id)
        expires_at = revoke_expiry(original, issued_at)
        try:
            wire = nf.build_broadcast(key, key_id=args.key_id, level=LEVEL_NAMES[original.level],
                                      message_id=message_id, issued_at=issued_at, expires_at=expires_at,
                                      content="", replaces=bytes.fromhex(original.message_id))
        except nf.NoticeError as e:
            raise ToolError(f"{original.message_id}：{e}") from None
        check_signed_by_published_key(wire, args.key_id, deps.public_keys_path)
        revokes.append((original, message_id, expires_at, wire))
    if not revokes:
        raise ToolError(f"batchId {args.batch} 的 {len(originals)} 則公告都已經被取代或撤回，沒有要撤回的")

    out = deps.stdout
    out.write("Admin Notice 純撤回（廣播 kind、空 body）\n")
    for original, message_id, expires_at, _ in revokes:
        out.write(f"  撤回       {original.describe()}\n"
                  f"             撤回的 messageId {message_id.hex()}，{local_time(expires_at)} 到期\n")
    out.write(f"  發出       {local_time(issued_at)}\n"
              f"  寫入       {'emulator' if endpoints.emulated else '正式環境'}的 Firestore（{project_id}）\n")
    if args.dry_run:
        for _, message_id, _, wire in revokes:
            out.write(f"wire {message_id.hex()}（{len(wire)} bytes）：{wire.hex()}\n")
        out.write("--dry-run：查過要撤回的公告，沒有寫入。\n")
        return 0
    if not args.yes:
        out.write("實地實驗進行中不要發公告（見 README.md）。撤回會送到所有裝置；沒收到的人會一直看到原公告到它過期。\n")
        if deps.input("確定撤回？輸入 yes 送出：").strip() != "yes":
            out.write("沒有送出。\n")
            return 1

    writes = []
    for original, message_id, expires_at, wire in revokes:
        record = notice_record(kind=nf.KIND_BROADCAST, level=LEVEL_NAMES[original.level], content="",
                               issued_at=issued_at, expires_at=expires_at,
                               replaces=bytes.fromhex(original.message_id), batch_id=message_id)
        writes += notice_writes(project_id, message_id=message_id, wire=wire, record=record, uid=uid)
    try:
        fb.commit(deps.post, endpoints, project_id, id_token, writes)
    except fb.FirebaseError as e:
        raise ToolError(f"寫入失敗：{e}{commit_hint(e)}") from None
    for original, message_id, _, _ in revokes:
        out.write(f"已寫入 admin_notices/{message_id.hex()} 與 {RECORDS}/{message_id.hex()}"
                  f"（撤回 {original.message_id}）。\n")
    return 0


def unique(values) -> list:
    """依原本的順序去掉重複。"""
    return list(dict.fromkeys(values or []))


def query_hint(error: fb.FirebaseError) -> str:
    if error.code == "PERMISSION_DENIED":
        return "\n被 security rules 擋下：這個帳號是 Administrator 嗎（admins/{uid} 要存在）？"
    if error.code == "FAILED_PRECONDITION":
        return ("\n以 Reporter Handle 查詢需要 installations.reporterHandle 的 collection group 索引，"
                "見 docs/MESH_GATEWAY.md 第 8 節。")
    return ""


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


UID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
HANDLE = re.compile(r"^[0-9a-f]{12}$")


def uid_arg(text: str) -> str:
    # 會拼進 Firestore 路徑（reporter_handles/{uid}），不能有 /。
    if not UID.match(text):
        raise argparse.ArgumentTypeError("uid 只能是 1–128 個英數字、- 或 _（Firebase Auth 的 uid）")
    return text


MESSAGE_ID_HEX = re.compile(r"^[0-9a-f]{16}$")


def message_id_arg(text: str) -> str:
    # 會拼進 Firestore 路徑（admin_notice_records/{messageId}），格式同 rules 檢查的文件 ID。
    if not MESSAGE_ID_HEX.match(text):
        raise argparse.ArgumentTypeError("messageId 是 16 個小寫十六進位字元，例如 admin_notices 的文件 ID")
    return text


def handle_arg(text: str) -> str:
    handle = text.strip().lower()
    if not HANDLE.match(handle):
        raise argparse.ArgumentTypeError("Reporter Handle 是 12 個十六進位字元，例如 mesh_reports 的文件 ID")
    return handle


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="admin_notice_tool.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    keygen = sub.add_parser("keygen", help="產生管理端 Ed25519 金鑰對，只印出公鑰")
    keygen.add_argument("--key-id", type=key_id_arg, default=0x01, help="金鑰的 keyId，預設 0x01")
    keygen.add_argument("--out", help="私鑰檔路徑，預設 ~/.config/cares-mesh/admin-notice/admin-ed25519-<keyId>.key")
    keygen.set_defaults(run=cmd_keygen)

    send = sub.add_parser("send", help="發一則廣播公告，或以 --uid／--handle 發定向公告",
                          description=f"沒有 --uid、--handle 時是廣播，送到所有裝置；有的話是定向公告，只有收件裝置"
                                      f"解得開。密碼從環境變數 {PASSWORD_ENV} 讀取，沒有設定就在終端機詢問；"
                                      "不接受命令列參數。")
    send.add_argument("--email", required=True, help="Administrator 帳號的 email")
    send.add_argument("--level", required=True, choices=list(LEVEL_NAMES), help="資訊、重要或緊急")
    send.add_argument("--content", required=True, help="公告內容，UTF-8 最多 300 bytes（約 100 個中文字）")
    send.add_argument("--valid-for", required=True, type=duration_ms, metavar="DURATION",
                      help="有效期，例如 6h、90m、1h30m，最長 24h")
    send.add_argument("--uid", action="append", type=uid_arg, metavar="UID",
                      help="定向公告的收件帳號：加密給它登記過的每台裝置。可以重複")
    send.add_argument("--handle", action="append", type=handle_arg, metavar="REPORTER_HANDLE",
                      help="定向公告的收件 Reporter Handle（一台裝置，例如 mesh_reports 上看到的）。可以重複")
    send.add_argument("--replaces", type=message_id_arg, metavar="MESSAGE_ID",
                      help="更正這則公告：它在 App 上標成「已更正」並連到新公告。新公告的到期不能早於它；"
                           "定向公告只能用定向公告（--uid／--handle）更正")
    send.add_argument("--key-id", type=key_id_arg, default=0x01, help="私鑰的 keyId，預設 0x01")
    send.add_argument("--key", help="私鑰檔路徑，預設 ~/.config/cares-mesh/admin-notice/admin-ed25519-<keyId>.key")
    send.add_argument("--project", help="Firestore 專案，預設讀 app/google-services.json")
    send.add_argument("--yes", action="store_true", help="不詢問，直接送出")
    send.add_argument("--dry-run", action="store_true",
                      help="只組包、簽章並印出，不寫入。廣播不登入；定向公告與更正會登入查收件裝置與被取代的那則")
    send.set_defaults(run=cmd_send)

    revoke = sub.add_parser("revoke", help="撤回一則公告，或以 --batch 撤回整批",
                            description="每一則各發一則純撤回：廣播 kind、空 body、replaces 填被撤回的那則，"
                                        "與它同時到期（快過期的至少留 1 小時）。不刪除任何 admin_notices 文件。"
                                        f"密碼從環境變數 {PASSWORD_ENV} 讀取，沒有設定就在終端機詢問。")
    revoke.add_argument("--email", required=True, help="Administrator 帳號的 email")
    target = revoke.add_mutually_exclusive_group(required=True)
    target.add_argument("message_id", nargs="?", type=message_id_arg, metavar="MESSAGE_ID",
                        help="要撤回的公告（admin_notices 的文件 ID）")
    target.add_argument("--batch", type=message_id_arg, metavar="BATCH_ID",
                        help="撤回 admin_notice_records 裡 batchId 相同的每一則（拆成多則的定向公告）")
    revoke.add_argument("--key-id", type=key_id_arg, default=0x01, help="私鑰的 keyId，預設 0x01")
    revoke.add_argument("--key", help="私鑰檔路徑，預設 ~/.config/cares-mesh/admin-notice/admin-ed25519-<keyId>.key")
    revoke.add_argument("--project", help="Firestore 專案，預設讀 app/google-services.json")
    revoke.add_argument("--yes", action="store_true", help="不詢問，直接送出")
    revoke.add_argument("--dry-run", action="store_true", help="登入查過要撤回的公告、簽好章並印出，不寫入")
    revoke.set_defaults(run=cmd_revoke)
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
