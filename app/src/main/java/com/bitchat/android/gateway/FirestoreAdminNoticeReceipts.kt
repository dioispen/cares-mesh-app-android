package com.bitchat.android.gateway

import android.util.Log
import com.bitchat.android.adminnotice.AdminNoticeReceipts
import com.bitchat.android.adminnotice.AdminNoticeSource
import com.google.android.gms.tasks.Task
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.util.Date

/**
 * [AdminNoticeReceipts] backed by Firestore (#143, docs/ADMIN_NOTICE_V1.md「回條」): each receipt is
 * a merge `set` of `admin_notices/{messageId}/receipts/{uid}` for the account signed in at that
 * moment, so a delivery and a later reading add up to one document per account, and the last of
 * that account's devices to write wins. Nobody signed in, or no Firebase in this process: nothing.
 *
 * Never waits for the server. A device that heard the notice over the mesh has no internet; its
 * write waits in the SDK's on-disk offline queue and goes out once the device is online (in a
 * restarted process, once the Gateway's listener starts Firestore; 待驗證 4). Unlike the Gateway's
 * uploads of other people's reports, receipts are this account's own data, like the
 * `reporter_handles` registration, so the offline queue is where they belong. Failures are logged.
 */
class FirestoreAdminNoticeReceipts internal constructor(
    /** The signed-in account's uid; throws IllegalStateException when Firebase is not initialised. */
    private val signedInUid: () -> String?,
    /** Merges [fields] into the document at the path given; the returned task is never awaited. */
    private val mergeInto: (path: String, fields: Map<String, Any>) -> Task<*>
) : AdminNoticeReceipts {

    override fun delivered(messageId: String, via: AdminNoticeSource, deliveredAtMs: Long) {
        write(messageId, deliveredReceipt(via, deliveredAtMs))
    }

    override fun read(messageId: String, readAtMs: Long) {
        write(messageId, readReceipt(readAtMs))
    }

    private fun write(messageId: String, fields: Map<String, Any>) {
        try {
            val uid = signedInUid() ?: return
            mergeInto(receiptPath(messageId, uid), fields)
                // Only once the server answers, maybe long after, maybe never in this process.
                .addOnFailureListener(Runnable::run) { e ->
                    Log.w(TAG, "Receipt for Admin Notice $messageId refused or lost: ${e.message}")
                }
        } catch (e: Exception) {
            Log.w(TAG, "No receipt for Admin Notice $messageId: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "AdminNoticeReceipts"

        /**
         * Cheap on the main thread: FirebaseAuth and Firestore are looked up on each write, on the
         * writer's thread, so a process without Firebase only logs.
         */
        fun create(): AdminNoticeReceipts = FirestoreAdminNoticeReceipts(
            signedInUid = { FirebaseAuth.getInstance().currentUser?.uid },
            mergeInto = { path, fields -> FirebaseFirestore.getInstance().document(path).set(fields, SetOptions.merge()) }
        )
    }
}

internal const val RECEIPTS = "receipts"

internal fun receiptPath(messageId: String, uid: String): String = "$ADMIN_NOTICES/$messageId/$RECEIPTS/$uid"

/** Delivered: when (this phone's clock) and how. `firestore.rules` requires both in every receipt. */
internal fun deliveredReceipt(via: AdminNoticeSource, deliveredAtMs: Long): Map<String, Any> = mapOf(
    "deliveredAt" to Timestamp(Date(deliveredAtMs)),
    "via" to when (via) {
        AdminNoticeSource.BACKEND -> "firestore"
        AdminNoticeSource.MESH -> "ble"
    }
)

/** Read: added to the receipt the delivery wrote; the rules refuse it on its own. */
internal fun readReceipt(readAtMs: Long): Map<String, Any> = mapOf("readAt" to Timestamp(Date(readAtMs)))
