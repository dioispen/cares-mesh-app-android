package com.bitchat.android.gateway

import android.os.Build
import com.bitchat.android.adminnotice.AdminNoticeSource
import com.google.android.gms.tasks.TaskCompletionSource
import com.google.firebase.Timestamp
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The receipts' thin Firestore adapter (#143): which document it merges into and with what, for
 * the signed-in account only, and that it hands the write to Firestore's offline queue without
 * waiting. The merge itself, and what the rules make of it, are `firestore-tests`' to check.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class FirestoreAdminNoticeReceiptsTest {

    private class Write(val path: String, val fields: Map<String, Any>)

    private val writes = mutableListOf<Write>()

    /** What Firestore gives back offline: a write the server never acknowledges. */
    private val pending = TaskCompletionSource<Void>()

    private var uid: () -> String? = { "uid-alice" }

    private val receipts = FirestoreAdminNoticeReceipts(
        signedInUid = { uid() },
        mergeInto = { path, fields ->
            writes += Write(path, fields)
            pending.task
        }
    )

    @Test
    fun `a delivery via Firestore is merged into the account's receipt with its phone time`() {
        receipts.delivered(MESSAGE_ID, AdminNoticeSource.BACKEND, deliveredAtMs = 1_792_627_260_123L)

        val write = writes.single()
        assertEquals("admin_notices/0f1e2d3c4b5a6978/receipts/uid-alice", write.path)
        assertEquals(
            mapOf("deliveredAt" to Timestamp(1_792_627_260L, 123_000_000), "via" to "firestore"),
            write.fields
        )
    }

    @Test
    fun `a delivery over the mesh says ble`() {
        receipts.delivered(MESSAGE_ID, AdminNoticeSource.MESH, deliveredAtMs = 1_792_627_260_000L)

        assertEquals(
            mapOf("deliveredAt" to Timestamp(1_792_627_260L, 0), "via" to "ble"),
            writes.single().fields
        )
    }

    @Test
    fun `a reading merges only readAt into the same receipt`() {
        receipts.read(MESSAGE_ID, readAtMs = 1_792_627_560_500L)

        val write = writes.single()
        assertEquals("admin_notices/0f1e2d3c4b5a6978/receipts/uid-alice", write.path)
        assertEquals(mapOf("readAt" to Timestamp(1_792_627_560L, 500_000_000)), write.fields)
    }

    @Test
    fun `each receipt goes to the account signed in when it is written`() {
        receipts.delivered(MESSAGE_ID, AdminNoticeSource.MESH, deliveredAtMs = 1_792_627_260_000L)
        uid = { "uid-bob" }
        receipts.read(MESSAGE_ID, readAtMs = 1_792_627_560_000L)

        assertEquals(
            listOf("admin_notices/0f1e2d3c4b5a6978/receipts/uid-alice", "admin_notices/0f1e2d3c4b5a6978/receipts/uid-bob"),
            writes.map { it.path }
        )
    }

    @Test
    fun `nobody signed in, nothing is written`() {
        uid = { null }

        receipts.delivered(MESSAGE_ID, AdminNoticeSource.MESH, deliveredAtMs = 1_792_627_260_000L)
        receipts.read(MESSAGE_ID, readAtMs = 1_792_627_560_000L)

        assertEquals(0, writes.size)
    }

    @Test
    fun `without Firebase in this process nothing is written and nothing is thrown`() {
        uid = { throw IllegalStateException("Default FirebaseApp is not initialized in this process") }

        receipts.delivered(MESSAGE_ID, AdminNoticeSource.MESH, deliveredAtMs = 1_792_627_260_000L)
        receipts.read(MESSAGE_ID, readAtMs = 1_792_627_560_000L)

        assertEquals(0, writes.size)
    }

    @Test
    fun `a write Firestore refuses at once is not thrown`() {
        val refusing = FirestoreAdminNoticeReceipts(
            signedInUid = { "uid-alice" },
            mergeInto = { _, _ -> throw IllegalArgumentException("Invalid document reference") }
        )

        refusing.delivered(MESSAGE_ID, AdminNoticeSource.MESH, deliveredAtMs = 1_792_627_260_000L)
        refusing.read(MESSAGE_ID, readAtMs = 1_792_627_560_000L)
    }

    // Offline, Firestore's task completes only once the server acknowledges, after the device is
    // back online: waiting for it would hold the Inbox's lock for as long as that lasts. Called on
    // a worker thread, as the Inbox and the bridge do (Tasks.await refuses the main thread).
    @Test
    fun `offline, the receipt is handed to Firestore's queue without waiting for the server`() {
        val writer = Thread {
            receipts.delivered(MESSAGE_ID, AdminNoticeSource.MESH, deliveredAtMs = 1_792_627_260_000L)
            receipts.read(MESSAGE_ID, readAtMs = 1_792_627_560_000L)
        }
        writer.start()
        writer.join(5_000L)

        assertEquals("returned while the server has not answered", false, writer.isAlive)
        assertEquals(2, writes.size)
        assertEquals(false, pending.task.isComplete)
    }

    @Test
    fun `a write the server refuses later is only logged`() {
        receipts.delivered(MESSAGE_ID, AdminNoticeSource.MESH, deliveredAtMs = 1_792_627_260_000L)

        pending.setException(IllegalStateException("PERMISSION_DENIED"))

        assertEquals(1, writes.size)
    }

    private companion object {
        const val MESSAGE_ID = "0f1e2d3c4b5a6978"
    }
}
