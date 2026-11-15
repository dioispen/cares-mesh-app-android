package com.bitchat.android.adminnotice

import com.bitchat.android.crypto.Ed25519Verification
import com.bitchat.android.util.hexEncodedString
import java.nio.ByteBuffer

enum class AdminNoticeKind(val wire: Int) {
    BROADCAST(0x01),

    /** 單播與組播: the content is encrypted to up to five recipient devices. */
    TARGETED(0x02);

    companion object {
        fun fromWire(value: Int): AdminNoticeKind? = entries.firstOrNull { it.wire == value }
    }
}

enum class AdminNoticeLevel(val wire: Int) {
    /** 資訊 */
    INFO(0x01),

    /** 重要 */
    IMPORTANT(0x02),

    /** 緊急 */
    URGENT(0x03);

    companion object {
        fun fromWire(value: Int): AdminNoticeLevel? = entries.firstOrNull { it.wire == value }
    }
}

/** The part of a payload after the header and before the signature; its layout depends on the kind. */
sealed interface AdminNoticeBody {
    /** 廣播 body: UTF-8 text, empty only for a pure revoke. */
    class Broadcast(val content: String) : AdminNoticeBody

    /** 定向 body, still encrypted; opening it needs this device's recipient key (#141). */
    class Targeted(
        val ephemeralPublicKey: ByteArray,
        val recipients: List<RecipientEntry>,
        val nonce: ByteArray,
        /** The AES-256-GCM ciphertext followed by its 16-byte tag; the header is the aad. */
        val ciphertext: ByteArray
    ) : AdminNoticeBody

    class RecipientEntry(val tag: ByteArray, val wrappedKey: ByteArray)
}

/**
 * An Admin Notice payload (docs/ADMIN_NOTICE_V1.md「Payload」): the Firestore `wire`, and the payload of
 * a 0x31 packet, byte for byte. [parse] only checks its shape (處理規則 steps 1–2 except the keyId
 * lookup); whether an Administrator signed it is [isSignedBy]'s question.
 */
class AdminNoticePayload private constructor(
    private val bytes: ByteArray,
    val kind: AdminNoticeKind,
    val keyId: Int,
    val level: AdminNoticeLevel,
    /** 16 lowercase hex characters, as in the `admin_notices/{messageId}` document ID. */
    val messageId: String,
    val issuedAtMs: Long,
    val expiresAtMs: Long,
    /** The messageId this notice corrects or withdraws; null when it replaces nothing. */
    val replaces: String?,
    val body: AdminNoticeBody
) {
    /** The payload exactly as received: what a Gateway injects and gossip sync carries. */
    val wire: ByteArray get() = bytes.copyOf()

    /** The 36-byte header, the aad of a targeted body. */
    val header: ByteArray get() = bytes.copyOfRange(0, HEADER_SIZE)

    /** Ed25519 over "CARES-ADMIN-NOTICE-v1" || payload[0 : len-64]（「簽章」）. */
    fun isSignedBy(publicKey: ByteArray): Boolean = Ed25519Verification.verify(
        signature = bytes.copyOfRange(bytes.size - SIGNATURE_SIZE, bytes.size),
        data = SIGNATURE_CONTEXT + bytes.copyOfRange(0, bytes.size - SIGNATURE_SIZE),
        publicKey = publicKey
    )

    sealed interface Parsed {
        class Valid(val payload: AdminNoticePayload) : Parsed
        class Invalid(val reason: AdminNoticeRejection) : Parsed
    }

    companion object {
        const val VERSION = 0x01
        const val HEADER_SIZE = 36
        const val SIGNATURE_SIZE = 64
        const val MESSAGE_ID_SIZE = 8
        const val MIN_SIZE = HEADER_SIZE + SIGNATURE_SIZE
        const val MAX_CONTENT_BYTES = 300
        const val MAX_RECIPIENTS = 5

        private const val EPHEMERAL_KEY_SIZE = 32
        private const val TAG_SIZE = 8
        private const val WRAPPED_KEY_SIZE = 32
        private const val NONCE_SIZE = 12
        private const val GCM_TAG_SIZE = 16

        private val SIGNATURE_CONTEXT = "CARES-ADMIN-NOTICE-v1".toByteArray(Charsets.US_ASCII)

        fun parse(wire: ByteArray): Parsed {
            if (wire.size < MIN_SIZE) return invalid(AdminNoticeRejection.MALFORMED)
            val header = ByteBuffer.wrap(wire, 0, HEADER_SIZE)
            val version = header.get().toInt() and 0xFF
            val kind = AdminNoticeKind.fromWire(header.get().toInt() and 0xFF)
            val keyId = header.get().toInt() and 0xFF
            val level = AdminNoticeLevel.fromWire(header.get().toInt() and 0xFF)
            if (version != VERSION || kind == null || level == null) return invalid(AdminNoticeRejection.UNSUPPORTED)
            val messageId = ByteArray(MESSAGE_ID_SIZE).also { header.get(it) }
            val issuedAt = header.getLong()
            val expiresAt = header.getLong()
            val replaces = ByteArray(MESSAGE_ID_SIZE).also { header.get(it) }
            // An all-zero messageId would read as "replaces nothing" when another notice names it.
            if (messageId.all { it == 0.toByte() }) return invalid(AdminNoticeRejection.MALFORMED)
            val replacesNothing = replaces.all { it == 0.toByte() }

            val body = wire.copyOfRange(HEADER_SIZE, wire.size - SIGNATURE_SIZE)
            val parsedBody = when (kind) {
                AdminNoticeKind.BROADCAST -> broadcastBody(body, replacesNothing)
                AdminNoticeKind.TARGETED -> targetedBody(body)
            } ?: return invalid(AdminNoticeRejection.MALFORMED)

            return Parsed.Valid(
                AdminNoticePayload(
                    bytes = wire.copyOf(),
                    kind = kind,
                    keyId = keyId,
                    level = level,
                    messageId = messageId.hexEncodedString(),
                    issuedAtMs = issuedAt,
                    expiresAtMs = expiresAt,
                    replaces = if (replacesNothing) null else replaces.hexEncodedString(),
                    body = parsedBody
                )
            )
        }

        /** 0–300 bytes of text; empty only when the notice withdraws another (純撤回). */
        private fun broadcastBody(body: ByteArray, replacesNothing: Boolean): AdminNoticeBody.Broadcast? {
            if (body.size > MAX_CONTENT_BYTES) return null
            if (body.isEmpty() && replacesNothing) return null
            return AdminNoticeBody.Broadcast(String(body, Charsets.UTF_8))
        }

        /** ephemeralPublicKey ‖ recipientCount ‖ (tag ‖ wrappedKey) × count ‖ nonce ‖ ciphertext ‖ GCM tag. */
        private fun targetedBody(body: ByteArray): AdminNoticeBody.Targeted? {
            if (body.size < EPHEMERAL_KEY_SIZE + 1) return null
            val count = body[EPHEMERAL_KEY_SIZE].toInt() and 0xFF
            if (count !in 1..MAX_RECIPIENTS) return null
            val entriesStart = EPHEMERAL_KEY_SIZE + 1
            val nonceStart = entriesStart + count * (TAG_SIZE + WRAPPED_KEY_SIZE)
            val ciphertextStart = nonceStart + NONCE_SIZE
            val contentBytes = body.size - ciphertextStart - GCM_TAG_SIZE
            if (contentBytes !in 0..MAX_CONTENT_BYTES) return null
            val recipients = (0 until count).map { i ->
                val entry = entriesStart + i * (TAG_SIZE + WRAPPED_KEY_SIZE)
                AdminNoticeBody.RecipientEntry(
                    tag = body.copyOfRange(entry, entry + TAG_SIZE),
                    wrappedKey = body.copyOfRange(entry + TAG_SIZE, entry + TAG_SIZE + WRAPPED_KEY_SIZE)
                )
            }
            return AdminNoticeBody.Targeted(
                ephemeralPublicKey = body.copyOfRange(0, EPHEMERAL_KEY_SIZE),
                recipients = recipients,
                nonce = body.copyOfRange(nonceStart, ciphertextStart),
                ciphertext = body.copyOfRange(ciphertextStart, body.size)
            )
        }

        private fun invalid(reason: AdminNoticeRejection) = Parsed.Invalid(reason)
    }
}
