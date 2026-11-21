package com.bitchat.android.adminnotice

import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.nio.ByteBuffer
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

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
    const val V2_EXPIRES_AT = 1_792_634_400_000L
    const val V2_CONTENT = "救援人員約 10 分鐘內抵達，請留在原地"

    /** The appendix's recipient keys (共用金鑰): V2 is encrypted to recipient-1 and recipient-2 only. */
    const val RECIPIENT_1_PRIVATE_HEX = "543430b3141351317d1fc752adafabb51eea760014c56ef649db958aee664b12"
    const val RECIPIENT_2_PRIVATE_HEX = "9ca79b4e47da69ee9e5f577e7354942ddae23de0df9bac70a03fc397827c1473"
    const val OUTSIDER_PRIVATE_HEX = "25c0ec1c0a16c67a57e0bd636008e61851a10ff8f27ebe488fd07cb570ef5ce0"

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

    const val V5_MESSAGE_ID = "7a5b3c1d9e8f6a42"
    const val V5_EXPIRES_AT = 1_792_641_600_000L

    /**
     * V5 targeted, urgent, five recipients and 300 bytes of content: a 661-byte payload, so its
     * 683-byte outer packet is split into two fragments on the mesh (實作前待驗證 1).
     */
    val V5 = hex(
        """
        010201037a5b3c1d9e8f6a42000001a160e85000000001a161c40a0000000000
        000000007ff2642665620d4564fdd4296d74d00b6d4345dbccce0804f17e97af
        da62b34c05d37191cc72eaab65dfb1ea60c9df00f27fd9be3fed2f4020b73319
        d86fe072243fa78dc224df5610a325be078784b61a875f8c9eadd66ff7242bc2
        f0d8f72d719c9b432e16acee746355242df5c99ade024b1a23ea7ee3c959ed79
        28d5a71177e828485ed2ffb645c469f863470df1a7e28d1b4d1b259b07c7cc64
        6682afe82ea810feb8d7441eea132d5c91a18f3d2c7f2d656d66f3f4b1f04521
        0a7fdebc099bee11ce396fb1f83f2e40b91fe3d64810f48e25dd53ecb32aa001
        935fb612ae83901c57df3e683c31aebc49d7fa19563d19c990a5ee2f217ec3fa
        bd86123a4e2ab0670e2afc48bed789652f5f766dffcda8969a562fbf772e9911
        39aa48514c42aa89dd2386e95f274d475910d598c78d213c674e9b50c2f5ae34
        da90b8e886dc49b7b5bd1b1b012b665f9cf4eaf3e6406855b065be62bab22a2f
        61292a78cc5b489c3be265d0b8f42e128ec985884202b5330f8fbdfe172ac1e6
        65b962cb3c475d453f1f634a679ec4be933d0c5b48c47aa878ca317cda590976
        9be4071579300e257f398cd3712c6a3c9c9a69290701caaf7d704383f2b2c0e2
        dea612f4cbf416ae9b6fef1ce95815fe96056f75e05e38007c22241bd8c8ea52
        82c37d4c17726c03c5bb8b042600c07aeb13c457148338286f45dc4394981196
        6a288361b0c7a7a233f103b42530816b9ec3ca9bbddc3986039adf1a1acb1f40
        f4f0f2bb51277bafd1c05d900469009d842249b19c512059f4288e4025e37b7d
        fe94ce27999fabcb74e189fda4d2544150001524ed1f3097a37cd57767258701
        3e722fa3b40b06ac612d5b8f0765d42af609796906
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

    /**
     * [wire] as a 0x31 packet heard over the mesh. By default the outer fields are what a Gateway
     * puts there (「外層封包」): senderID = messageId, timestamp = issuedAt; a relay took one hop.
     */
    fun meshPacket(
        wire: ByteArray,
        senderID: ByteArray = wire.copyOfRange(4, 12),
        timestamp: Long = ByteBuffer.wrap(wire, 12, 8).getLong(),
        ttl: UByte = 6u
    ): BitchatPacket = BitchatPacket(
        version = 1u,
        type = MessageType.ADMIN_NOTICE.value,
        senderID = senderID,
        recipientID = null,
        timestamp = timestamp.toULong(),
        payload = wire,
        signature = null,
        ttl = ttl
    )

    /** A targeted body (定向 body) of the right shape; its contents are random-looking filler. */
    fun targetedBody(recipientCount: Int, contentBytes: Int): ByteArray =
        ByteArray(32) { 0x11 } + byteArrayOf(recipientCount.toByte()) +
            ByteArray(40 * recipientCount) { 0x22 } + ByteArray(12) { 0x33 } +
            ByteArray(contentBytes + 16) { 0x44 }

    /**
     * [wire] with [tamper] applied to everything before its signature, then signed again with the
     * test key: the signature holds, so whatever fails afterwards is not step 4.
     */
    fun resigned(wire: ByteArray, tamper: (ByteArray) -> Unit): ByteArray {
        val unsigned = wire.copyOf(wire.size - 64).also(tamper)
        return unsigned + sign("CARES-ADMIN-NOTICE-v1".toByteArray(Charsets.US_ASCII) + unsigned)
    }

    /**
     * A targeted notice encrypted to [recipients] (their `noticePublicKey`s) as the spec's 管理端加密
     * does, with fresh random keys, signed with the test key. For keys no vector covers, such as one
     * the production key store generated; the vectors (V2) pin the format itself.
     */
    fun targeted(
        recipients: List<ByteArray>,
        content: String,
        messageId: String = "2233445566778899",
        expiresAt: Long = VECTOR_ISSUED_AT + 3_600_000L,
        replaces: String = "0000000000000000"
    ): ByteArray {
        val random = SecureRandom()
        val ephemeral = X25519PrivateKeyParameters(random)
        val ephemeralPublic = ephemeral.generatePublicKey().encoded
        val contentKey = ByteArray(32).also(random::nextBytes)
        val nonce = ByteArray(12).also(random::nextBytes)
        val header = ByteBuffer.allocate(36)
            .put(0x01).put(0x02).put(0x01).put(0x02)
            .put(hex(messageId)).putLong(VECTOR_ISSUED_AT).putLong(expiresAt).put(hex(replaces))
            .array()
        val entries = recipients.fold(ByteArray(0)) { acc, recipient ->
            val shared = ByteArray(32)
            X25519Agreement().apply { init(ephemeral) }.calculateAgreement(X25519PublicKeyParameters(recipient, 0), shared, 0)
            val okm = ByteArray(40)
            HKDFBytesGenerator(SHA256Digest()).apply {
                init(HKDFParameters(shared, hex(messageId), "CARES-ADMIN-NOTICE-v1/recipient".toByteArray(Charsets.US_ASCII) + ephemeralPublic + recipient))
            }.generateBytes(okm, 0, 40)
            acc + okm.copyOfRange(0, 8) + ByteArray(32) { i -> (contentKey[i].toInt() xor okm[8 + i].toInt()).toByte() }
        }
        val ciphertext = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(contentKey, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(header)
            doFinal(content.toByteArray(Charsets.UTF_8))
        }
        val unsigned = header + ephemeralPublic + byteArrayOf(recipients.size.toByte()) + entries + nonce + ciphertext
        return unsigned + sign("CARES-ADMIN-NOTICE-v1".toByteArray(Charsets.US_ASCII) + unsigned)
    }

    private fun sign(message: ByteArray): ByteArray = Ed25519Signer().run {
        init(true, Ed25519PrivateKeyParameters(hex(TEST_ADMIN_SEED_HEX), 0))
        update(message, 0, message.size)
        generateSignature()
    }
}

/**
 * The injection delay's scheduler, driven by hand: [advance] runs, in order, what has come due.
 * Its own time starts at 0; tests move the Inbox clock alongside it.
 */
internal class ManualScheduler : AdminNoticeScheduler {
    private class Task(val dueAtMs: Long, val action: () -> Unit) {
        var cancelled = false
    }

    private var timeMs = 0L
    private val tasks = mutableListOf<Task>()

    /** Every delay asked for, in order. */
    val delays = mutableListOf<Long>()

    /** Scheduled, not yet run and not cancelled. */
    val pending: Int get() = tasks.count { !it.cancelled }

    override fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
        delays += delayMs
        val task = Task(timeMs + delayMs, action)
        tasks += task
        return { task.cancelled = true }
    }

    fun advance(ms: Long) {
        timeMs += ms
        while (true) {
            val due = tasks.filter { !it.cancelled && it.dueAtMs <= timeMs }.minByOrNull { it.dueAtMs } ?: return
            tasks.remove(due)
            due.action()
        }
    }
}

/** A mesh service that records what a Gateway injects; [accepts] false plays one that cannot send. */
internal class RecordingInjector(var accepts: Boolean = true) : AdminNoticeInjector {
    val injected = mutableListOf<BitchatPacket>()

    override fun inject(packet: BitchatPacket): Boolean {
        if (accepts) injected += packet
        return accepts
    }
}

/** A mesh service's sync set that records what the Inbox offers it and takes back. */
internal class RecordingSyncSet : AdminNoticeSyncSet {
    /** Each offered packet with its expiresAt, in order. */
    val added = mutableListOf<Pair<BitchatPacket, Long>>()
    val removed = mutableListOf<String>()

    override fun add(packet: BitchatPacket, expiresAtMs: Long) {
        added += packet to expiresAtMs
    }

    override fun remove(messageId: String) {
        removed += messageId
    }

    /** The messageIds offered, in order. */
    fun messageIds(): List<String> = added.map { (packet, _) -> packet.senderID.joinToString("") { "%02x".format(it) } }
}

/**
 * This device's recipient key as the Inbox sees it, over a fixed X25519 private key (one of the
 * appendix's), or none. [clear] plays a sign-out (`adminNotice_clearKey`).
 */
internal class FakeRecipientKey(privateKeyHex: String?) : AdminNoticeRecipientKey {
    private var privateKey: X25519PrivateKeyParameters? = privateKeyHex?.let { X25519PrivateKeyParameters(hex(it), 0) }

    fun clear() {
        privateKey = null
    }

    override fun publicKey(): ByteArray? = privateKey?.generatePublicKey()?.encoded

    override fun agree(ephemeralPublicKey: ByteArray): ByteArray? {
        val key = privateKey ?: return null
        val shared = ByteArray(32)
        X25519Agreement().apply { init(key) }
            .calculateAgreement(X25519PublicKeyParameters(ephemeralPublicKey, 0), shared, 0)
        return shared
    }
}
