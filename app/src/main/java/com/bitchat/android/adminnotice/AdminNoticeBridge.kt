package com.bitchat.android.adminnotice

import android.util.Log

/**
 * Process-wide hook handing Admin Notices to the [AdminNoticeInbox]: `VerifiedHealthReportBridge`
 * in the opposite direction. There the protocol layer publishes and the Gateway listens; here the
 * Gateway's Firestore listener (`gateway/`, the only side that touches Firebase) publishes `wire`
 * and the Inbox receives it, so neither the Inbox nor `mesh/` depends on Firebase. #137 hands the
 * mesh's 0x31 packets to the same Inbox through here.
 *
 * One Inbox per process, installed by [AdminNotices.install] when the App starts: its dedup table
 * must outlive any one mesh service instance and serve the mesh whether or not the foreground
 * service (and with it the Firestore listener) runs.
 */
object AdminNoticeBridge {
    private const val TAG = "AdminNoticeBridge"

    @Volatile
    private var inbox: AdminNoticeInbox? = null

    @Synchronized
    fun install(inbox: AdminNoticeInbox) {
        this.inbox = inbox
    }

    /** Removes [inbox] only if it is still the installed one. */
    @Synchronized
    fun uninstall(inbox: AdminNoticeInbox) {
        if (this.inbox === inbox) this.inbox = null
    }

    /**
     * Called by the Gateway's Firestore listener with a document's `wire`. Null when no Inbox is
     * installed or it failed; a failure must not stop the listener.
     */
    fun deliverFromBackend(wire: ByteArray): AdminNoticeOutcome? {
        val current = inbox ?: return null
        return try {
            current.onBackendNotice(wire)
        } catch (e: Exception) {
            Log.w(TAG, "Admin Notice from the backend not processed: ${e.message}")
            null
        }
    }
}
