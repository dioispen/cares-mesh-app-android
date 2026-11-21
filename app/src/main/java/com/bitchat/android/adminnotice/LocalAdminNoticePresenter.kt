package com.bitchat.android.adminnotice

import android.util.Log

/** Posts the system notification for a notice; Android's in production, a fake in tests. */
interface AdminNoticeNotifier {
    fun notify(notice: ReceivedAdminNotice)

    /** Takes back the notification of [messageId], if one is showing (撤回與取代). */
    fun cancel(messageId: String)
}

/**
 * The Inbox's [AdminNoticePresenter] on a phone: store the notice, and notify only when it was not
 * stored before, so neither a second path nor an App restart notifies twice (收件端呈現).
 *
 * A corrected or withdrawn notice (撤回與取代) is marked so in the store, which erases its content,
 * and its notification is cancelled: a stale order must not stay in the notification shade. A
 * correction then arrives as a notice of its own and is notified under its own messageId, alerting
 * again on its level's channel, because what the user was told to do has changed.
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

    override fun correct(messageId: String, correctedBy: String) =
        takeBack(messageId) { store.markCorrected(messageId, correctedBy) }

    override fun withdraw(messageId: String) = takeBack(messageId) { store.markWithdrawn(messageId) }

    /**
     * The notification is cancelled whatever the store says: it may have been posted although the
     * notice could not be stored, and cancelling one that is gone does nothing. Neither failure
     * reaches the Inbox, which would otherwise not relay the notice that replaced it.
     */
    private fun takeBack(messageId: String, mark: () -> StoredAdminNotice?) {
        try {
            mark()
        } catch (e: Exception) {
            Log.w(TAG, "Could not mark Admin Notice $messageId as replaced: ${e.message}")
        }
        try {
            notifier.cancel(messageId)
        } catch (e: Exception) {
            Log.w(TAG, "Could not cancel the notification of Admin Notice $messageId: ${e.message}")
        }
    }

    private companion object {
        const val TAG = "LocalAdminNoticePresenter"
    }
}
