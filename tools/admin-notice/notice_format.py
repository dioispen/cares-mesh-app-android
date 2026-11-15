"""Admin Notice payload 的組包、簽章與檢查（docs/ADMIN_NOTICE_V1.md「線路格式」）。

gen_test_vectors.py 與發送工具 admin_notice_tool.py 共用這一份，附錄的 test vectors 與
實際寫進 Firestore 的 wire 才會出自同一段程式碼。
"""

import hmac
import secrets
import struct

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

VERSION = 0x01
KIND_BROADCAST = 0x01
KIND_TARGETED = 0x02
LEVEL_INFO, LEVEL_IMPORTANT, LEVEL_URGENT = 0x01, 0x02, 0x03

SIGNATURE_CONTEXT = b"CARES-ADMIN-NOTICE-v1"
RECIPIENT_INFO = b"CARES-ADMIN-NOTICE-v1/recipient"
HEADER_SIZE = 36
SIGNATURE_SIZE = 64
MESSAGE_ID_SIZE = 8
NO_REPLACES = bytes(MESSAGE_ID_SIZE)

LEVELS = (LEVEL_INFO, LEVEL_IMPORTANT, LEVEL_URGENT)
MAX_CONTENT_BYTES = 300
MAX_VALIDITY_MS = 24 * 3600_000


class NoticeError(ValueError):
    """這則公告違反 docs/ADMIN_NOTICE_V1.md 的格式或上限，App 會丟掉它，所以不簽。"""


def new_message_id(random_bytes=secrets.token_bytes) -> bytes:
    """安全亂數的 messageId。全為 0 保留給「沒有 replaces」，抽到就重抽。"""
    while True:
        message_id = random_bytes(MESSAGE_ID_SIZE)
        if message_id != NO_REPLACES:
            return message_id


def check_header_fields(*, key_id: int, level: int, message_id: bytes, issued_at: int,
                        expires_at: int, replaces: bytes):
    """App 收到 0x31 時的第 2、5、6 步裡，管理端自己就能先擋下的部分。"""
    if not 0x01 <= key_id <= 0xFF:
        raise NoticeError(f"keyId 0x{key_id:02x} 無效：0x00 保留不用")
    if level not in LEVELS:
        raise NoticeError(f"level 0x{level:02x} 無效，只能是資訊 0x01、重要 0x02、緊急 0x03")
    if len(message_id) != MESSAGE_ID_SIZE or message_id == NO_REPLACES:
        raise NoticeError("messageId 必須是 8 bytes，且不得全為 0")
    if len(replaces) != MESSAGE_ID_SIZE:
        raise NoticeError("replaces 必須是 8 bytes，全為 0 表示沒有")
    if replaces == message_id:
        raise NoticeError("公告不能取代自己")
    if not issued_at < expires_at <= issued_at + MAX_VALIDITY_MS:
        raise NoticeError("有效期必須大於 0、不超過 24 小時")


def encode_content(content: str) -> bytes:
    body = content.encode("utf-8")
    if len(body) > MAX_CONTENT_BYTES:
        raise NoticeError(f"內容 {len(body)} bytes，超過 {MAX_CONTENT_BYTES} bytes 的上限")
    return body


def raw_public(key) -> bytes:
    return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def raw_private(key) -> bytes:
    return key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                             serialization.NoEncryption())


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def header(kind, key_id, level, message_id, issued_at, expires_at, replaces) -> bytes:
    h = bytes([VERSION, kind, key_id, level]) + message_id + struct.pack(">QQ", issued_at, expires_at) + replaces
    assert len(h) == HEADER_SIZE
    return h


def sign(admin: Ed25519PrivateKey, unsigned: bytes) -> bytes:
    """unsigned 是 header ‖ body；回傳加上管理端簽章的完整 payload。"""
    return unsigned + admin.sign(SIGNATURE_CONTEXT + unsigned)


def verify(admin_pub: bytes, payload: bytes):
    """簽章不對時丟 cryptography.exceptions.InvalidSignature。"""
    Ed25519PublicKey.from_public_bytes(admin_pub).verify(
        payload[-SIGNATURE_SIZE:], SIGNATURE_CONTEXT + payload[:-SIGNATURE_SIZE])


def build_broadcast(admin: Ed25519PrivateKey, *, key_id: int, level: int, message_id: bytes,
                    issued_at: int, expires_at: int, content: str,
                    replaces: bytes = NO_REPLACES) -> bytes:
    """組一則廣播並簽章。content 空字串加上 replaces 就是純撤回。違反格式或上限丟 NoticeError。"""
    check_header_fields(key_id=key_id, level=level, message_id=message_id, issued_at=issued_at,
                        expires_at=expires_at, replaces=replaces)
    body = encode_content(content)
    if not body and replaces == NO_REPLACES:
        raise NoticeError("內容是空的：只有撤回（replaces 不為 0）時才可以不帶內容")
    hdr = header(KIND_BROADCAST, key_id, level, message_id, issued_at, expires_at, replaces)
    return sign(admin, hdr + body)


def recipient_secrets(shared: bytes, message_id: bytes, eph_pub: bytes, rcpt_pub: bytes):
    okm = hkdf_sha256(shared, message_id, RECIPIENT_INFO + eph_pub + rcpt_pub, 40)
    return okm[:8], okm[8:]


def targeted_body(hdr, message_id, eph, recipients, content_key, nonce, content):
    """定向 body（docs/ADMIN_NOTICE_V1.md「定向 body」）。回傳 body 與每個收件裝置的中間值。"""
    eph_pub = raw_public(eph)
    entries, trace = b"", []
    for r_pub in recipients:
        shared = eph.exchange(X25519PublicKey.from_public_bytes(r_pub))
        tag, kek = recipient_secrets(shared, message_id, eph_pub, r_pub)
        wrapped = bytes(a ^ b for a, b in zip(content_key, kek))
        entries += tag + wrapped
        trace.append({"shared": shared, "tag": tag, "kek": kek, "wrapped": wrapped})
    ciphertext = AESGCM(content_key).encrypt(nonce, content, hdr)
    body = eph_pub + bytes([len(recipients)]) + entries + nonce + ciphertext
    return body, trace


def open_as_recipient(payload: bytes, rcpt: X25519PrivateKey):
    """收件端流程：比對 tag、解開 content key、解密。不是收件者回傳 None。"""
    hdr, body = payload[:HEADER_SIZE], payload[HEADER_SIZE:-SIGNATURE_SIZE]
    message_id = hdr[4:12]
    eph_pub, count = body[:32], body[32]
    entries = body[33:33 + 40 * count]
    nonce = body[33 + 40 * count:45 + 40 * count]
    ciphertext = body[45 + 40 * count:]
    r_pub = raw_public(rcpt)
    shared = rcpt.exchange(X25519PublicKey.from_public_bytes(eph_pub))
    tag, kek = recipient_secrets(shared, message_id, eph_pub, r_pub)
    for i in range(count):
        entry = entries[40 * i:40 * (i + 1)]
        if hmac.compare_digest(entry[:8], tag):
            content_key = bytes(a ^ b for a, b in zip(entry[8:], kek))
            return AESGCM(content_key).decrypt(nonce, ciphertext, hdr)
    return None
