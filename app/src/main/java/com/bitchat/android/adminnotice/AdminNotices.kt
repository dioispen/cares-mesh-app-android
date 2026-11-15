package com.bitchat.android.adminnotice

import android.content.Context
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Builds this process's [AdminNoticeInbox] and installs it in [AdminNoticeBridge]. Called once from
 * `BitchatApplication.onCreate`, so the Inbox and its in-memory dedup table live exactly as long as
 * the process (an App restart starts them empty, as the spec expects), across mesh service
 * instances, and whether or not `MeshForegroundService` runs.
 *
 * Cheap on the main thread: the encrypted store opens on first use, which happens on the Firestore
 * listener's own thread.
 */
object AdminNotices {
    fun install(context: Context) {
        val appContext = context.applicationContext
        val presenter = LocalAdminNoticePresenter(
            store = EncryptedAdminNoticeStore.open(appContext),
            notifier = SystemAdminNoticeNotifier(appContext),
            nowMs = System::currentTimeMillis
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
                )
            )
        )
    }

    private fun scheduledOn(executor: ScheduledExecutorService) = AdminNoticeScheduler { delayMs, action ->
        val future = executor.schedule(action, delayMs, TimeUnit.MILLISECONDS)
        return@AdminNoticeScheduler { future.cancel(false) }
    }
}
