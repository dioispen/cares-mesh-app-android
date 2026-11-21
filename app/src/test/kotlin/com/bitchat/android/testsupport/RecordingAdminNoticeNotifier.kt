package com.bitchat.android.testsupport

import com.bitchat.android.adminnotice.AdminNoticeNotifier
import com.bitchat.android.adminnotice.ReceivedAdminNotice

/** Records the Admin Notice notifications posted and cancelled, by messageId, in order. */
internal class RecordingAdminNoticeNotifier : AdminNoticeNotifier {
    val notified = mutableListOf<String>()
    val cancelled = mutableListOf<String>()

    override fun notify(notice: ReceivedAdminNotice) {
        notified += notice.messageId
    }

    override fun cancel(messageId: String) {
        cancelled += messageId
    }
}
