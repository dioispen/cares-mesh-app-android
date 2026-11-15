package com.bitchat.android.gateway

import android.util.Log
import com.google.firebase.Timestamp
import com.google.firebase.firestore.Blob
import com.google.firebase.firestore.DocumentChange
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.MetadataChanges
import java.util.Date
import java.util.concurrent.Executor

/**
 * [AdminNoticeFeed] backed by a Firestore snapshot listener on `admin_notices` (docs/ADMIN_NOTICE_V1.md
 * 「Gateway：從 Firestore 注入 mesh」). Thin on purpose: [AdminNoticeSubscription] decides when to
 * listen, and the Inbox decides what a `wire` is worth; this only queries, picks the added documents'
 * `wire`, and sorts Firestore's errors.
 *
 * Metadata changes are included so that the switch from the local cache to the server shows up,
 * which is what resets the subscription's backoff; they cost no reads. Firestore's offline cache
 * stays on: Flutter shares this instance (ADR-0009), and cached notices are processed like any other.
 */
class FirestoreAdminNoticeFeed(
    private val firestore: FirebaseFirestore,
    /** Where Firestore reports; the Inbox's work then runs off the main thread. */
    private val executor: Executor
) : AdminNoticeFeed {

    override fun listen(sinceMs: Long, events: AdminNoticeFeed.Events): AdminNoticeFeed.Registration {
        val registration = firestore.collection(ADMIN_NOTICES)
            .whereGreaterThan(EXPIRES_AT, Timestamp(Date(sinceMs)))
            .addSnapshotListener(executor, MetadataChanges.INCLUDE) { snapshot, error ->
                when {
                    error != null -> {
                        Log.w(TAG, "admin_notices listener failed (${error.code.name})")
                        events.onError(classifyListenerError(error))
                    }
                    snapshot != null -> events.onAdded(
                        addedWires(snapshot.documentChanges.map { it.type to it.document.get(WIRE) }),
                        snapshot.metadata.isFromCache
                    )
                }
            }
        return AdminNoticeFeed.Registration { registration.remove() }
    }

    private companion object {
        const val TAG = "FirestoreAdminNoticeFeed"
        const val EXPIRES_AT = "expiresAt"
    }
}

internal const val ADMIN_NOTICES = "admin_notices"
internal const val WIRE = "wire"

/**
 * Only added documents carry a notice to process. A removed document is not a withdrawal (only a
 * revoke notice is), and a modified one is metadata: the rules forbid updating a notice. Nothing but
 * the `wire` bytes is read, so a document without them is skipped.
 */
internal fun addedWires(changes: List<Pair<DocumentChange.Type, Any?>>): List<ByteArray> =
    changes.mapNotNull { (type, wire) ->
        if (type == DocumentChange.Type.ADDED) (wire as? Blob)?.toBytes() else null
    }

/** PERMISSION_DENIED waits for a sign-in change; everything else is retried with backoff. */
internal fun classifyListenerError(e: FirebaseFirestoreException): AdminNoticeFeed.Error =
    if (e.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) {
        AdminNoticeFeed.Error.PERMISSION_DENIED
    } else {
        AdminNoticeFeed.Error.RETRYABLE
    }
