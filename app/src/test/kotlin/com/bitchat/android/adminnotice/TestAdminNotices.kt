package com.bitchat.android.adminnotice

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.nio.ByteBuffer

/** Hex → bytes for test literals; whitespace (the spec wraps payloads) is ignored. */
internal fun hex(text: String): ByteArray {
    val digits = text.filterNot { it.isWhitespace() }
    require(digits.length % 2 == 0) { "odd hex length" }
    return ByteArray(digits.length / 2) { digits.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

/**
 * The appendix test vectors of docs/ADMIN_NOTICE_V1.md, and notices signed on the fly with the same
 * test key for the cases the vectors do not cover. The key's private seed is published in the spec:
 * test-only, never part of [AdminKeyTable.PRODUCTION].
 */
internal object TestAdminNotices {
    const val TEST_ADMIN_SEED_HEX = "1400079ad9d2b9d0728405120c081de046ea67a696bbbc1575b97ba7d8d03085"
    const val TEST_ADMIN_PUBLIC_KEY_HEX = "10f835a2f82b877a2c1c705ef3c71d3640a40b4e39f6ca4197c17eaefb05a176"

    /** The table a test Inbox trusts: only the test-vector key, under keyId 0x01. */
    val TEST_KEYS = AdminKeyTable(mapOf(0x01 to hex(TEST_ADMIN_PUBLIC_KEY_HEX)))

    /** issuedAt of V1 and V2: 2026-10-22T00:00:00Z. */
    const val VECTOR_ISSUED_AT = 1_792_627_200_000L

    const val V1_MESSAGE_ID = "a1b2c3d4e5f60718"
    const val V1_EXPIRES_AT = 1_792_648_800_000L
    const val V1_CONTENT = "土石流警戒：請立即撤離至大同國小避難所"

    /** V1 broadcast, urgent. */
    val V1 = hex(
        """
        01010103a1b2c3d4e5f60718000001a160e85000000001a16231e70000000000
        00000000e59c9fe79fb3e6b581e8ada6e68892efbc9ae8ab8be7ab8be58db3e6
        92a4e99ba2e887b3e5a4a7e5908ce59c8be5b08fe981bfe99ba3e689805c770d
        5b6d3a8d4165dd74006650f7c96b1fab54ec1340438ad884db367d8a7f2d0288
        9bc878922000ad2616d9dbaa019eeaeeecc4af17d7813bb76eb8a5a60b
        """
    )

    const val V2_MESSAGE_ID = "0f1e2d3c4b5a6978"

    /** V2 targeted, important, two recipients. */
    val V2 = hex(
        """
        010201020f1e2d3c4b5a6978000001a160e85000000001a161562d0000000000
        00000000a722369abb0be24a97efa8dba00415b782bd5cd532f5e8f95987deb5
        2161d90002b043ecb010281c9b3254bda912b5c0b8301862853f0abf819378c9
        81bb379ff31070f1252eaeb19ecd088fb1bd9143ce43fb345512ecf908e41ec2
        e45803d25bea94f03a26de91c2192764c31b4e8b6eb843ea2414803cdaa677b4
        324f0050264e816da8b115eab31257532f764ffd206d987e2c08186fe49189cc
        8f9c68eb3b19dd9a3aef555d8a1c7a5b7237a4f26a436230b849125eb14fb732
        fed8ea7eb2e6449ee9b545e158b8a68e24b6e4cc687ed7268cb41dfd34f59918
        328a56cbb2237ecacd35555446cb428df5e6fc4b95b6590d8f0342f1a3c729c0
        f03e58540d
        """
    )

    const val V3_MESSAGE_ID = "5566778899aabbcc"

    /** V3 pure revoke of V1: broadcast kind, empty body, replaces = V1. */
    val V3 = hex(
        """
        010101035566778899aabbcc000001a160f177c0000001a16231e700a1b2c3d4
        e5f60718906c626ca840e351bfaa44b6778bc7ca50e99aa5470cb920602c403d
        45763debcff0ff88c8cd9d7db40447416a64671333382ec93cd5f3fda36fcbe1
        f5b54301
        """
    )

    /** V4: V1 with its level tampered (0x03 → 0x01); the signature must fail. */
    val V4 = hex(
        """
        01010101a1b2c3d4e5f60718000001a160e85000000001a16231e70000000000
        00000000e59c9fe79fb3e6b581e8ada6e68892efbc9ae8ab8be7ab8be58db3e6
        92a4e99ba2e887b3e5a4a7e5908ce59c8be5b08fe981bfe99ba3e689805c770d
        5b6d3a8d4165dd74006650f7c96b1fab54ec1340438ad884db367d8a7f2d0288
        9bc878922000ad2616d9dbaa019eeaeeecc4af17d7813bb76eb8a5a60b
        """
    )

    /**
     * A notice laid out as in the spec's 線路格式 and signed with the test key, so a test can reach
     * the checks that come after the signature. Every field can be bent out of shape.
     */
    fun signed(
        messageId: String = "1122334455667788",
        kind: Int = 0x01,
        keyId: Int = 0x01,
        level: Int = 0x02,
        issuedAt: Long = VECTOR_ISSUED_AT,
        expiresAt: Long = VECTOR_ISSUED_AT + 3_600_000L,
        replaces: String = "0000000000000000",
        body: ByteArray = "收容所已開放".toByteArray(Charsets.UTF_8),
        version: Int = 0x01
    ): ByteArray {
        val unsigned = ByteBuffer.allocate(36 + body.size)
            .put(version.toByte()).put(kind.toByte()).put(keyId.toByte()).put(level.toByte())
            .put(hex(messageId))
            .putLong(issuedAt)
            .putLong(expiresAt)
            .put(hex(replaces))
            .put(body)
            .array()
        return unsigned + sign("CARES-ADMIN-NOTICE-v1".toByteArray(Charsets.US_ASCII) + unsigned)
    }

    /** A targeted body (定向 body) of the right shape; its contents are random-looking filler. */
    fun targetedBody(recipientCount: Int, contentBytes: Int): ByteArray =
        ByteArray(32) { 0x11 } + byteArrayOf(recipientCount.toByte()) +
            ByteArray(40 * recipientCount) { 0x22 } + ByteArray(12) { 0x33 } +
            ByteArray(contentBytes + 16) { 0x44 }

    private fun sign(message: ByteArray): ByteArray = Ed25519Signer().run {
        init(true, Ed25519PrivateKeyParameters(hex(TEST_ADMIN_SEED_HEX), 0))
        update(message, 0, message.size)
        generateSignature()
    }
}
