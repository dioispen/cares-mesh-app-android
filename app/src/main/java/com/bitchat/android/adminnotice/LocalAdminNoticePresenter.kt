package com.bitchat.android.adminnotice

import android.util.Log

/** Posts the system notification for a notice; Android's in production, a fake in tests. */
interface AdminNoticeNotifier {
    fun notify(notice: ReceivedAdminNotice)
}

/**
 * The Inbox's [AdminNoticePresenter] on a phone: store the notice, and notify only when it was not
 * stored before, so neither a second path nor an App restart notifies twice (收件端呈現). A
 * targeted notice stored for the first time also gets its delivery receipt (#143).
 */
class LocalAdminNoticePresenter(
    private val store: AdminNoticeStore,
    private val notifier: AdminNoticeNotifier,
    private val nowMs: () -> Long,
    private val receipts: AdminNoticeReceipts = AdminNoticeReceipts.NONE
) : AdminNoticePresenter {

    override fun present(notice: ReceivedAdminNotice) {
        val now = nowMs()
        val firstTime = try {
            store.insertIfAbsent(
                StoredAdminNotice(
                    messageId = notice.messageId,
                    kind = notice.kind,
                    level = notice.level,
                    issuedAtMs = notice.issuedAtMs,
                    expiresAtMs = notice.expiresAtMs,
                    replaces = notice.replaces,
                    content = notice.content,
                    status = AdminNoticeStatus.ACTIVE,
                    receivedAtMs = now
                )
            )
        } catch (e: Exception) {
            // An evacuation order matters more than a duplicate after a restart: the Inbox's
            // in-memory dedup still keeps this process from notifying it twice.
            Log.w(TAG, "Could not store Admin Notice ${notice.messageId}; notifying anyway: ${e.message}")
            true
        }
        if (!firstTime) return
        notifier.notify(notice)
        // Only on the first insert: after a restart the listener reads every unexpired notice
        // again, and a second receipt would move deliveredAt and could turn `ble` into `firestore`.
        if (notice.kind == AdminNoticeKind.TARGETED) deliveredReceipt(notice, now)
    }

    /**
     * An exception here would reach the mesh as "do not relay", for a notice already recorded as in
     * the mesh: a receipt that cannot be written is only logged.
     */
    private fun deliveredReceipt(notice: ReceivedAdminNotice, now: Long) {
        try {
            receipts.delivered(notice.messageId, notice.source, now)
        } catch (e: Exception) {
            Log.w(TAG, "No delivery receipt for Admin Notice ${notice.messageId}: ${e.message}")
        }
    }

    private companion object {
        const val TAG = "LocalAdminNoticePresenter"
    }
}
