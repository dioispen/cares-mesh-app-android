package com.bitchat.android.gateway

import android.os.Build
import com.google.firebase.firestore.Blob
import com.google.firebase.firestore.DocumentChange.Type
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.FirebaseFirestoreException.Code
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The thin Firestore adapter of the Admin Notice listener (#136): only added documents' `wire`
 * bytes pass, and Firestore's errors are sorted into PERMISSION_DENIED and retryable. The listener
 * itself is left to the device acceptance tests.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class FirestoreAdminNoticeFeedTest {

    @Test
    fun `only added documents are handed over, removals and modifications are ignored`() {
        val wires = addedWires(
            listOf(
                Type.ADDED to Blob.fromBytes(byteArrayOf(1)),
                Type.REMOVED to Blob.fromBytes(byteArrayOf(2)),
                Type.MODIFIED to Blob.fromBytes(byteArrayOf(3)),
                Type.ADDED to Blob.fromBytes(byteArrayOf(4))
            )
        )

        assertEquals(listOf(1, 4), wires.map { it.single().toInt() })
    }

    @Test
    fun `a document whose wire is not bytes is skipped`() {
        val wires = addedWires(listOf(Type.ADDED to "0101", Type.ADDED to null, Type.ADDED to Blob.fromBytes(byteArrayOf(7))))

        assertArrayEquals(byteArrayOf(7), wires.single())
    }

    @Test
    fun `PERMISSION_DENIED is told apart from errors worth retrying`() {
        assertEquals(AdminNoticeFeed.Error.PERMISSION_DENIED, classifyListenerError(firestoreError(Code.PERMISSION_DENIED)))

        for (code in listOf(Code.RESOURCE_EXHAUSTED, Code.UNAVAILABLE, Code.UNAUTHENTICATED, Code.INTERNAL, Code.FAILED_PRECONDITION)) {
            assertEquals(code.name, AdminNoticeFeed.Error.RETRYABLE, classifyListenerError(firestoreError(code)))
        }
    }

    private fun firestoreError(code: Code) = FirebaseFirestoreException(code.name, code)
}
