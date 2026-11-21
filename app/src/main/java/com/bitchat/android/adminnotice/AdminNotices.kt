package com.bitchat.android.adminnotice

import android.content.Context
import com.bitchat.android.identity.AdminNoticeRecipientKeyStore
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Builds this process's [AdminNoticeInbox] and installs it in [AdminNoticeBridge]. Called once from
 * `BitchatApplication.onCreate`, so the Inbox and its in-memory dedup table live exactly as long as
 * the process (an App restart starts them empty, as the spec expects), across mesh service
 * instances, and whether or not `MeshForegroundService` runs.
 *
 * Cheap on the main thread: the encrypted notice store and the recipient key store open on first
 * use, which happens on the Firestore listener's or the mesh's own thread.
 */
object AdminNotices {
    @Volatile
    private var store: AdminNoticeStore? = null

    /**
     * The one notice store of this process: the Inbox's presenter writes it, the Flutter bridge
     * lists it and hears of its changes. Cheap to call; the file opens on first use.
     */
    fun store(context: Context): AdminNoticeStore =
        store ?: synchronized(this) {
            store ?: EncryptedAdminNoticeStore.open(context.applicationContext, nowMs = System::currentTimeMillis)
                .also { store = it }
        }

    /**
     * Where this process's receipts go (#143): the delivery receipts the Inbox's presenter writes,
     * and the read receipts `FlutterChatActivity` wires into its bridge. [AdminNoticeReceipts.NONE]
     * until [install].
     */
    @Volatile
    var receipts: AdminNoticeReceipts = AdminNoticeReceipts.NONE
        private set

    /**
     * [receipts] is passed in, not built here: its Firestore implementation lives in `gateway/`,
     * the only Kotlin package that uses Firebase.
     */
    fun install(context: Context, receipts: AdminNoticeReceipts) {
        val appContext = context.applicationContext
        this.receipts = receipts
        val presenter = LocalAdminNoticePresenter(
            store = store(appContext),
            notifier = SystemAdminNoticeNotifier(appContext),
            nowMs = System::currentTimeMillis,
            receipts = receipts
        )
        AdminNoticeBridge.install(
            AdminNoticeInbox(
                adminKeys = AdminKeyTable.PRODUCTION,
                presenter = presenter,
                nowMs = System::currentTimeMillis,
                injectionScheduler = scheduledOn(
                    // Lives with the process, like the Inbox; idle but for a Gateway's injections.
                    Executors.newSingleThreadScheduledExecutor { runnable ->
                        Thread(runnable, "AdminNoticeInjection").apply { isDaemon = true }
                    }
                ),
                // The Flutter bridge's instance: a sign-out's clearKey reaches the Inbox at once.
                recipientKey = StoredAdminNoticeRecipientKey { AdminNoticeRecipientKeyStore.getInstance(appContext) }
            )
        )
    }

    private fun scheduledOn(executor: ScheduledExecutorService) = AdminNoticeScheduler { delayMs, action ->
        val future = executor.schedule(action, delayMs, TimeUnit.MILLISECONDS)
        return@AdminNoticeScheduler { future.cancel(false) }
    }
}
