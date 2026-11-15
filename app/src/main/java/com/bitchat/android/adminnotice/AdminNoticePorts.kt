package com.bitchat.android.adminnotice

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
}

sealed interface AdminNoticeOutcome {
    /** Verified and new; recorded in the dedup table. */
    class Accepted(val payload: AdminNoticePayload) : AdminNoticeOutcome

    /** Verified, but this messageId was already recorded. */
    data object Duplicate : AdminNoticeOutcome

    data class Rejected(val reason: AdminNoticeRejection) : AdminNoticeOutcome
}
