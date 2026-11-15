package com.bitchat.android.adminnotice

import android.util.Log

/** Posts the system notification for a notice; Android's in production, a fake in tests. */
interface AdminNoticeNotifier {
    fun notify(notice: ReceivedAdminNotice)
}

/**
 * The Inbox's [AdminNoticePresenter] on a phone: store the notice, and notify only when it was not
 * stored before, so neither a second path nor an App restart notifies twice (收件端呈現).
 */
class LocalAdminNoticePresenter(
    private val store: AdminNoticeStore,
    private val notifier: AdminNoticeNotifier,
    private val nowMs: () -> Long
) : AdminNoticePresenter {

    override fun present(notice: ReceivedAdminNotice) {
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
                    receivedAtMs = nowMs()
                )
            )
        } catch (e: Exception) {
            // An evacuation order matters more than a duplicate after a restart: the Inbox's
            // in-memory dedup still keeps this process from notifying it twice.
            Log.w(TAG, "Could not store Admin Notice ${notice.messageId}; notifying anyway: ${e.message}")
            true
        }
        if (firstTime) notifier.notify(notice)
    }

    private companion object {
        const val TAG = "LocalAdminNoticePresenter"
    }
}
