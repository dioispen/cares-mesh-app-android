#!/usr/bin/env python3
"""產生 docs/ADMIN_NOTICE_V1.md 附錄的 test vectors。

所有金鑰、nonce、時間都是固定值，輸出可重現。Kotlin（App）與 Dart（管理端）的
實作各自對照這份輸出寫單元測試。組包與簽章用的是發送工具同一份 notice_format.py。
需要 `pip install cryptography`。

用法：python tools/admin-notice/gen_test_vectors.py
輸出必須與附錄一致，由 test_gen_test_vectors.py 檢查。
"""

import hashlib
from datetime import datetime, timezone

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from notice_format import (KIND_TARGETED, LEVEL_IMPORTANT, LEVEL_INFO, LEVEL_URGENT,
                           NO_REPLACES, build_broadcast, header, open_as_recipient, raw_private,
                           raw_public, sign, targeted_body, verify)


def seed(label: str) -> bytes:
    return hashlib.sha256(label.encode()).digest()


def ms(iso: str) -> int:
    return int(datetime.fromisoformat(iso).replace(tzinfo=timezone.utc).timestamp() * 1000)


def wrap_hex(data: bytes, width: int = 64) -> str:
    h = data.hex()
    return "\n".join(h[i:i + width] for i in range(0, len(h), width))


def section(title: str, fields: dict):
    print(f"### {title}\n\n```text")
    for k, v in fields.items():
        if isinstance(v, bytes):
            text = wrap_hex(v)
            if "\n" in text:
                print(f"{k}:")
                print("\n".join("  " + line for line in text.split("\n")))
            else:
                print(f"{k}: {text}")
        else:
            print(f"{k}: {v}")
    print("```\n")


def main():
    admin = Ed25519PrivateKey.from_private_bytes(seed("cares-admin-notice-test/admin"))
    admin_pub = raw_public(admin)
    r1 = X25519PrivateKey.from_private_bytes(seed("cares-admin-notice-test/recipient-1"))
    r2 = X25519PrivateKey.from_private_bytes(seed("cares-admin-notice-test/recipient-2"))
    outsider = X25519PrivateKey.from_private_bytes(seed("cares-admin-notice-test/outsider"))
    eph = X25519PrivateKey.from_private_bytes(seed("cares-admin-notice-test/ephemeral"))
    content_key = seed("cares-admin-notice-test/content-key")
    nonce = seed("cares-admin-notice-test/nonce")[:12]

    issued = ms("2026-10-22T00:00:00")
    key_id = 0x01

    section("共用金鑰", {
        "admin Ed25519 seed": seed("cares-admin-notice-test/admin"),
        "admin Ed25519 public (keyId 0x01)": admin_pub,
        "recipient-1 X25519 private": raw_private(r1),
        "recipient-1 X25519 public": raw_public(r1),
        "recipient-2 X25519 private": raw_private(r2),
        "recipient-2 X25519 public": raw_public(r2),
        "outsider X25519 private（不是收件者）": raw_private(outsider),
    })

    # V1：廣播
    mid1 = bytes.fromhex("a1b2c3d4e5f60718")
    content1 = "土石流警戒：請立即撤離至大同國小避難所".encode()
    p1 = build_broadcast(admin, key_id=key_id, level=LEVEL_URGENT, message_id=mid1, issued_at=issued,
                         expires_at=issued + 6 * 3600_000, content=content1.decode())
    verify(admin_pub, p1)
    section("V1 廣播（緊急）", {
        "messageId": mid1, "issuedAt": issued, "expiresAt": issued + 6 * 3600_000,
        "content (UTF-8)": content1.decode(), "content bytes": len(content1),
        "payload bytes": len(p1), "payload": p1,
    })

    # V2：組播給 recipient-1、recipient-2
    mid2 = bytes.fromhex("0f1e2d3c4b5a6978")
    content2 = "救援人員約 10 分鐘內抵達，請留在原地".encode()
    hdr2 = header(KIND_TARGETED, key_id, LEVEL_IMPORTANT, mid2, issued, issued + 2 * 3600_000, NO_REPLACES)
    body2, trace = targeted_body(hdr2, mid2, eph, [raw_public(r1), raw_public(r2)], content_key, nonce, content2)
    p2 = sign(admin, hdr2 + body2)
    verify(admin_pub, p2)
    assert open_as_recipient(p2, r1) == content2
    assert open_as_recipient(p2, r2) == content2
    assert open_as_recipient(p2, outsider) is None
    section("V2 組播（重要，2 位收件者）", {
        "messageId": mid2, "issuedAt": issued, "expiresAt": issued + 2 * 3600_000,
        "content (UTF-8)": content2.decode(), "content bytes": len(content2),
        "ephemeral X25519 private": raw_private(eph),
        "ephemeral X25519 public": raw_public(eph),
        "contentKey": content_key, "nonce": nonce,
        "recipient-1 shared": trace[0]["shared"], "recipient-1 tag": trace[0]["tag"],
        "recipient-1 kek": trace[0]["kek"], "recipient-1 wrappedKey": trace[0]["wrapped"],
        "recipient-2 tag": trace[1]["tag"], "recipient-2 wrappedKey": trace[1]["wrapped"],
        "payload bytes": len(p2), "payload": p2,
    })

    # V3：撤回 V1
    mid3 = bytes.fromhex("5566778899aabbcc")
    p3 = build_broadcast(admin, key_id=key_id, level=LEVEL_URGENT, message_id=mid3, issued_at=issued + 600_000,
                         expires_at=issued + 6 * 3600_000, content="", replaces=mid1)
    verify(admin_pub, p3)
    section("V3 撤回 V1（不帶內容的取代）", {
        "messageId": mid3, "issuedAt": issued + 600_000, "expiresAt": issued + 6 * 3600_000,
        "replaces": mid1, "payload bytes": len(p3), "payload": p3,
    })

    # V4：簽章被竄改，必須拒收
    tampered = bytearray(p1)
    tampered[3] = LEVEL_INFO
    try:
        verify(admin_pub, bytes(tampered))
        raise AssertionError("tampered payload verified")
    except Exception as e:
        if isinstance(e, AssertionError):
            raise
    section("V4 竄改 V1 的 level（0x03 → 0x01），驗簽必須失敗", {"payload": bytes(tampered)})


if __name__ == "__main__":
    main()
