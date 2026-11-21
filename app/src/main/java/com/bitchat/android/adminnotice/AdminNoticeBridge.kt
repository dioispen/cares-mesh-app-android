package com.bitchat.android.adminnotice

import android.util.Log
import com.bitchat.android.protocol.BitchatPacket

/**
 * Process-wide hook handing Admin Notices to the [AdminNoticeInbox]: `VerifiedHealthReportBridge`
 * in the opposite direction. There the protocol layer publishes and the Gateway listens; here the
 * Gateway's Firestore listener (`gateway/`, the only side that touches Firebase) publishes `wire`,
 * the mesh publishes the 0x31 packets it hears, and the Inbox receives both, so neither the Inbox
 * nor `mesh/` depends on Firebase. The running mesh service also attaches itself here as the
 * Inbox's injector and sync set.
 *
 * One Inbox per process, installed by [AdminNotices.install] when the App starts: its dedup table
 * must outlive any one mesh service instance and serve the mesh whether or not the foreground
 * service (and with it the Firestore listener) runs.
 */
object AdminNoticeBridge {
    private const val TAG = "AdminNoticeBridge"

    @Volatile
    private var inbox: AdminNoticeInbox? = null

    @Synchronized
    fun install(inbox: AdminNoticeInbox) {
        this.inbox = inbox
    }

    /** Removes [inbox] only if it is still the installed one. */
    @Synchronized
    fun uninstall(inbox: AdminNoticeInbox) {
        if (this.inbox === inbox) this.inbox = null
    }

    /**
     * Called by the Gateway's Firestore listener with a document's `wire`. Null when no Inbox is
     * installed or it failed; a failure must not stop the listener.
     */
    fun deliverFromBackend(wire: ByteArray): AdminNoticeOutcome? {
        val current = inbox ?: return null
        return try {
            current.onBackendNotice(wire)
        } catch (e: Exception) {
            Log.w(TAG, "Admin Notice from the backend not processed: ${e.message}")
            null
        }
    }

    /**
     * Called by the mesh's packet processor with a 0x31 packet; returns its `validPacket`, whether
     * to relay it. False without an Inbox or when it failed: what nothing verified is not relayed.
     */
    fun deliverFromMesh(packet: BitchatPacket): Boolean {
        val current = inbox ?: return false
        return try {
            current.onMeshPacket(packet).relay
        } catch (e: Exception) {
            Log.w(TAG, "Admin Notice from the mesh not processed: ${e.message}")
            false
        }
    }

    /**
     * The mesh service started and can broadcast: this Gateway injects through [injector], and
     * [syncSet], its gossip sync, is handed the notices already in the mesh and each one entering it.
     */
    fun attachMesh(injector: AdminNoticeInjector, syncSet: AdminNoticeSyncSet) {
        val current = inbox ?: return
        current.attachSyncSet(syncSet)
        current.attachInjector(injector)
    }

    /** The mesh service stopped: the Inbox cancels the injections waiting for it and stops offering it notices. */
    fun detachMesh(injector: AdminNoticeInjector, syncSet: AdminNoticeSyncSet) {
        val current = inbox ?: return
        current.detachInjector(injector)
        current.detachSyncSet(syncSet)
    }
}
