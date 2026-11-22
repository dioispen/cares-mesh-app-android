package com.bitchat.android.gateway

/**
 * What [AdminNoticeSubscription] needs from Firestore: one snapshot listener on `admin_notices`.
 * [FirestoreAdminNoticeFeed] in production, a fake in tests.
 */
interface AdminNoticeFeed {
    /** Listens to the notices whose `expiresAt` is after [sinceMs] until the registration is removed. */
    fun listen(sinceMs: Long, events: Events): Registration

    interface Events {
        /** The `wire` of every document a snapshot added, whether it came from the local cache or not. */
        fun onAdded(wires: List<ByteArray>, fromCache: Boolean)

        /** The listener failed and Firestore has already ended it. */
        fun onError(error: Error)
    }

    fun interface Registration {
        fun remove()
    }

    enum class Error {
        /** The rules refused the query: retrying cannot help until the sign-in state changes. */
        PERMISSION_DENIED,

        /** RESOURCE_EXHAUSTED (the Spark quota), UNAVAILABLE, and anything else that may pass later. */
        RETRYABLE
    }
}

/**
 * The Gateway's listener on `admin_notices`, as a state machine without Firebase (「Gateway：從
 * Firestore 注入 mesh」): attached while an account is signed in, re-attached when the account
 * changes, each time for the notices expiring after that moment. Every added document's `wire`,
 * including those from Firestore's local cache, goes to [deliver]; removals mean nothing.
 *
 * A failed listener is never re-attached at once, which would burn what is left of the read quota
 * and leave even Health Reports unreadable: a retryable error waits [initialBackoffMs], doubling up
 * to [maxBackoffMs] until a snapshot from the server shows Firestore answers again. PERMISSION_DENIED
 * stays detached until the sign-in state changes.
 *
 * Thread-safe: sign-in changes, Firestore callbacks and retries may arrive on different threads.
 * [deliver] runs outside the lock, on the thread Firestore reports on.
 */
class AdminNoticeSubscription(
    private val feed: AdminNoticeFeed,
    private val scheduler: Scheduler,
    private val nowMs: () -> Long,
    private val deliver: (ByteArray) -> Unit,
    private val initialBackoffMs: Long = INITIAL_BACKOFF_MS,
    private val maxBackoffMs: Long = MAX_BACKOFF_MS
) {
    /** Runs an action after a delay; the returned function cancels it. */
    fun interface Scheduler {
        fun schedule(delayMs: Long, action: () -> Unit): () -> Unit
    }

    private var stopped = false
    private var uid: String? = null
    private var registration: AdminNoticeFeed.Registration? = null
    private var cancelRetry: (() -> Unit)? = null
    private var backoffMs = initialBackoffMs

    /** Tells the events of the current registration apart from those of one already replaced. */
    private var generation = 0L

    /** The signed-in uid from FirebaseAuth; null when signed out. */
    @Synchronized
    fun onSignedIn(uid: String?) {
        if (stopped || uid == this.uid) return
        this.uid = uid
        detach()
        backoffMs = initialBackoffMs
        if (uid != null) attach()
    }

    /** The mesh service is going away: detach for good. */
    @Synchronized
    fun stop() {
        stopped = true
        detach()
    }

    private fun attach() {
        val current = ++generation
        registration = feed.listen(nowMs(), object : AdminNoticeFeed.Events {
            override fun onAdded(wires: List<ByteArray>, fromCache: Boolean) = added(current, wires, fromCache)
            override fun onError(error: AdminNoticeFeed.Error) = failed(current, error)
        })
    }

    /** Removes the listener and any pending retry; their late events are ignored from now on. */
    private fun detach() {
        generation++
        registration?.remove()
        registration = null
        cancelRetry?.invoke()
        cancelRetry = null
    }

    private fun added(generation: Long, wires: List<ByteArray>, fromCache: Boolean) {
        synchronized(this) {
            if (stopped || generation != this.generation) return
            if (!fromCache) backoffMs = initialBackoffMs
        }
        wires.forEach(deliver)
    }

    @Synchronized
    private fun failed(generation: Long, error: AdminNoticeFeed.Error) {
        if (stopped || generation != this.generation) return
        detach()
        when (error) {
            AdminNoticeFeed.Error.PERMISSION_DENIED -> Unit // until onSignedIn sees a change
            AdminNoticeFeed.Error.RETRYABLE -> {
                val wait = backoffMs
                backoffMs = minOf(backoffMs * 2, maxBackoffMs)
                val retry = this.generation
                cancelRetry = scheduler.schedule(wait) { retry(retry) }
            }
        }
    }

    @Synchronized
    private fun retry(generation: Long) {
        if (stopped || generation != this.generation || uid == null) return
        cancelRetry = null
        attach()
    }

    companion object {
        /** listener 退避: 1 分鐘起、指數增加、最長 30 分鐘. */
        const val INITIAL_BACKOFF_MS = 60_000L
        const val MAX_BACKOFF_MS = 30 * 60_000L
    }
}
