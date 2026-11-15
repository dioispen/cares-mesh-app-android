package com.bitchat.android.adminnotice

import com.bitchat.android.protocol.BitchatPacket

/** A verified Admin Notice this device can read, as handed to [AdminNoticePresenter]. */
data class ReceivedAdminNotice(
    val messageId: String,
    val kind: AdminNoticeKind,
    val level: AdminNoticeLevel,
    val issuedAtMs: Long,
    val expiresAtMs: Long,
    /** The messageId this notice corrects; null when it replaces nothing. */
    val replaces: String?,
    /** The text: a broadcast's body, or a targeted notice's content as decrypted for this device. */
    val content: String,
    /** Where this device got the copy it presents: what a receipt's `via` reports (#143). */
    val source: AdminNoticeSource
)

/** How a notice reached this device. Each notice is presented once, from the first copy that arrives. */
enum class AdminNoticeSource {
    /** Read from Firestore `admin_notices` by this device's Gateway listener: a receipt says `via = firestore`. */
    BACKEND,

    /** Heard over the mesh as a 0x31 packet: a receipt says `via = ble`. */
    MESH
}

/**
 * 收件者加密金鑰: this device's Admin Notice recipient key, through which the Inbox opens targeted
 * notices. The private key stays behind this port; the Inbox only gets the public key `R` and the
 * X25519 `shared` secret. In production the process-wide `identity/AdminNoticeRecipientKeyStore`
 * ([StoredAdminNoticeRecipientKey]), so a sign-out (`adminNotice_clearKey`) takes effect at once.
 *
 * Called on the Inbox's caller thread while the Inbox holds its lock; may read encrypted storage.
 */
interface AdminNoticeRecipientKey {
    /** This device's public key `R` (32 bytes); null when there is none (never signed in, or signed out). */
    fun publicKey(): ByteArray?

    /**
     * X25519 of this device's private key with a targeted notice's [ephemeralPublicKey]; null when
     * there is no key or the result would be all zeros. Null means "not for this device".
     */
    fun agree(ephemeralPublicKey: ByteArray): ByteArray?

    companion object {
        /** A device that holds no recipient key: it opens no targeted notice. */
        val NONE: AdminNoticeRecipientKey = object : AdminNoticeRecipientKey {
            override fun publicKey(): ByteArray? = null
            override fun agree(ephemeralPublicKey: ByteArray): ByteArray? = null
        }
    }
}

/**
 * 本機呈現: the Inbox's output to the device's own store and notifications. Called on the Inbox's
 * caller thread while the Inbox holds its lock, in the order notices were accepted, so it must not
 * call back into the Inbox.
 */
interface AdminNoticePresenter {
    fun present(notice: ReceivedAdminNotice)
}

/**
 * 注入封包: the running mesh service, through which a Gateway puts a notice it read from the
 * backend on the mesh. Called on the injection scheduler's thread while the Inbox holds its lock,
 * so it must not call back into the Inbox.
 */
fun interface AdminNoticeInjector {
    /**
     * Broadcasts [packet] exactly as given — normalized, with no device signature and no route
     * (ADR-0011) — and returns whether the mesh took it. False leaves the notice waiting.
     */
    fun inject(packet: BitchatPacket): Boolean
}

/**
 * Runs an action after a delay (the Gateway's injection delay). The returned function cancels it.
 * The action must run on another thread than [schedule]'s caller, never inline.
 */
fun interface AdminNoticeScheduler {
    fun schedule(delayMs: Long, action: () -> Unit): () -> Unit
}

sealed interface AdminNoticeOutcome {
    /** For a copy heard over the mesh, its `validPacket`: only an accepted copy is relayed (step 12). */
    val relay: Boolean get() = this is Accepted

    /**
     * Verified and taken in. New to this device, or, heard over the mesh, a notice this Gateway had
     * only read from the backend (presented then, not again).
     */
    class Accepted(val payload: AdminNoticePayload) : AdminNoticeOutcome

    /** Verified, but this messageId was already recorded (from the mesh: already in the mesh). */
    data object Duplicate : AdminNoticeOutcome

    data class Rejected(val reason: AdminNoticeRejection) : AdminNoticeOutcome
}
