package com.bitchat.android.gateway

import android.util.Log
import com.bitchat.android.adminnotice.AdminNoticeBridge
import com.bitchat.android.adminnotice.AdminNoticeOutcome
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * The inbound direction of the Gateway as it runs inside MeshForegroundService (#136, ADR-0011):
 * wires [AdminNoticeSubscription] to the sign-in state FirebaseAuth shares with Flutter and to
 * Firestore, and hands every `wire` to the Inbox through [AdminNoticeBridge], so the Inbox never
 * sees Firebase. Same lifetime and habits as [MeshGatewayRuntime]: the service starts it in
 * onCreate and stops it in onDestroy, and it is not created when the process has no Firebase.
 * The "relay nearby reports" switch does not apply: it governs only the outbound direction.
 */
class AdminNoticeListenerRuntime internal constructor(
    private val auth: FirebaseAuth,
    private val subscription: AdminNoticeSubscription,
    /** Releases what start() built around the subscription (the listener's thread). */
    private val onStopped: () -> Unit = {}
) {
    /** Called at once with the current user when added, then on every sign-in and sign-out. */
    private val authListener = FirebaseAuth.AuthStateListener { firebaseAuth ->
        subscription.onSignedIn(firebaseAuth.currentUser?.uid)
    }

    internal fun start() {
        auth.addAuthStateListener(authListener)
    }

    fun stop() {
        auth.removeAuthStateListener(authListener)
        subscription.stop()
        onStopped()
    }

    companion object {
        private const val TAG = "AdminNoticeListener"

        /** Null when Firebase is not available in this process; the mesh then runs without it. */
        fun start(): AdminNoticeListenerRuntime? {
            val (auth, firestore) = try {
                FirebaseAuth.getInstance() to FirebaseFirestore.getInstance()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "Firebase is not initialised; no Admin Notice listener: ${e.message}")
                return null
            }
            // One thread for Firestore's callbacks and the retries: verifying and storing a notice
            // stays off the main thread, in arrival order.
            val thread = Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, TAG).apply { isDaemon = true }
            }
            // A snapshot already on its way when the service stops must not fail inside Firestore.
            val callbacks = Executor { task ->
                try {
                    thread.execute(task)
                } catch (e: RejectedExecutionException) {
                    // Stopped: nobody listens any more.
                }
            }
            val subscription = AdminNoticeSubscription(
                feed = FirestoreAdminNoticeFeed(firestore, callbacks),
                scheduler = scheduledOn(thread),
                nowMs = System::currentTimeMillis,
                deliver = ::deliver
            )
            return AdminNoticeListenerRuntime(auth, subscription, onStopped = { thread.shutdownNow() })
                .also { it.start() }
        }

        private fun deliver(wire: ByteArray) {
            when (val outcome = AdminNoticeBridge.deliverFromBackend(wire)) {
                // A refused backend copy is a wrong key or someone writing past the rules: worth a log.
                is AdminNoticeOutcome.Rejected -> Log.w(TAG, "Refused an admin_notices document: ${outcome.reason}")
                is AdminNoticeOutcome.Accepted -> Log.i(TAG, "Admin Notice ${outcome.payload.messageId} received from Firestore")
                AdminNoticeOutcome.Duplicate, null -> Unit
            }
        }

        private fun scheduledOn(executor: ScheduledExecutorService) = AdminNoticeSubscription.Scheduler { delayMs, action ->
            val future = executor.schedule(action, delayMs, TimeUnit.MILLISECONDS)
            return@Scheduler { future.cancel(false) }
        }
    }
}
