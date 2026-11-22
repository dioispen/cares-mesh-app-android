package com.bitchat.android.adminnotice

/**
 * 回條 (#143, docs/ADMIN_NOTICE_V1.md「回條」): what this device tells the Administrators about a
 * targeted notice it opened — when it arrived and through which path, and when the user first read
 * it in the App. Broadcasts have no receipts. Firebase-free; in production
 * `gateway/FirestoreAdminNoticeReceipts`, which writes `admin_notices/{messageId}/receipts/{uid}`
 * for the signed-in account through Firestore's offline queue.
 *
 * Both calls must return at once and never wait for the network: [delivered] runs while the Inbox
 * holds its lock, [read] on the Flutter bridge's store thread. Times are this phone's clock.
 */
interface AdminNoticeReceipts {
    /** A targeted notice was opened and presented here, from its first copy that came [via]. */
    fun delivered(messageId: String, via: AdminNoticeSource, deliveredAtMs: Long)

    /** The user read the targeted notice [messageId] in the App for the first time. */
    fun read(messageId: String, readAtMs: Long)

    companion object {
        /** No backend to report to (Firebase is not part of this process): nothing is written. */
        val NONE: AdminNoticeReceipts = object : AdminNoticeReceipts {
            override fun delivered(messageId: String, via: AdminNoticeSource, deliveredAtMs: Long) = Unit
            override fun read(messageId: String, readAtMs: Long) = Unit
        }
    }
}

/**
 * The Flutter bridge's `onFirstRead` (`flutter/AdminNoticeBridge`): [notice] was just marked read
 * for the first time, with its readAt set. A targeted notice's reading becomes its read receipt;
 * a broadcast's, which the bridge reports too, writes nothing.
 */
fun AdminNoticeReceipts.recordFirstRead(notice: StoredAdminNotice) {
    if (notice.kind != AdminNoticeKind.TARGETED) return
    read(notice.messageId, notice.readAtMs ?: return)
}
