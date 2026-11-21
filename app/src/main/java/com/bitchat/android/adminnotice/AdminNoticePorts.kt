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
    /** The text: a broadcast's body, or (#141) a targeted notice's decrypted content. */
    val content: String
)

/**
 * 本機呈現: the Inbox's output to the device's own store and notifications. Called on the Inbox's
 * caller thread while the Inbox holds its lock, in the order notices were accepted, so it must not
 * call back into the Inbox.
 */
interface AdminNoticePresenter {
    fun present(notice: ReceivedAdminNotice)

    /**
     * 已更正 (撤回與取代, step 9): the verified notice [correctedBy] replaced [messageId], whose
     * content is not to be acted on any more. Called before [correctedBy] itself is presented, if
     * this device can read it. [messageId] may never have been presented here; then there is
     * nothing to mark. By default nothing is shown, so nothing changes.
     */
    fun correct(messageId: String, correctedBy: String) {}

    /**
     * 已撤回 (撤回與取代, step 9): a verified pure revoke withdrew [messageId]. As for [correct],
     * [messageId] may never have been presented here.
     */
    fun withdraw(messageId: String) {}
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
 * 加入 sync 集合: the running mesh service's gossip sync (#138), which offers each notice in the
 * mesh to neighbors that lack it until the notice expires, so that devices arriving late still get
 * it. Called while the Inbox holds its lock, so it must not call back into the Inbox.
 */
interface AdminNoticeSyncSet {
    /** Offers [packet], a verified notice's normalized outer packet, until [expiresAtMs]. */
    fun add(packet: BitchatPacket, expiresAtMs: Long)

    /** Stops offering the notice [messageId] (16 lowercase hex characters): one a later notice replaced (#139). */
    fun remove(messageId: String)
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
