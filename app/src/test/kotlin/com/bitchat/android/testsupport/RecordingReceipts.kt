package com.bitchat.android.testsupport

import com.bitchat.android.adminnotice.AdminNoticeReceipts
import com.bitchat.android.adminnotice.AdminNoticeSource

/** A delivery receipt as the port was asked to write it. */
internal data class Delivered(val messageId: String, val via: AdminNoticeSource, val deliveredAtMs: Long)

/** A read receipt as the port was asked to write it. */
internal data class Read(val messageId: String, val readAtMs: Long)

/** The receipt port, recording what it is asked to write; [failWith] plays one that throws. */
internal class RecordingReceipts(var failWith: Exception? = null) : AdminNoticeReceipts {
    val delivered = mutableListOf<Delivered>()
    val read = mutableListOf<Read>()

    override fun delivered(messageId: String, via: AdminNoticeSource, deliveredAtMs: Long) {
        failWith?.let { throw it }
        delivered += Delivered(messageId, via, deliveredAtMs)
    }

    override fun read(messageId: String, readAtMs: Long) {
        failWith?.let { throw it }
        read += Read(messageId, readAtMs)
    }
}
