package com.bitchat.android.identity

import android.content.Context
import android.content.SharedPreferences
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.util.Base64
import java.util.UUID

/** The Admin Notice recipient key (#140, docs/ADMIN_NOTICE_V1.md 收件者加密金鑰). */
@RunWith(RobolectricTestRunner::class)
class AdminNoticeRecipientKeyStoreTest {

    private val storage: SharedPreferences = RuntimeEnvironment.getApplication()
        .getSharedPreferences("admin-notice-key-${UUID.randomUUID()}", Context.MODE_PRIVATE)
    private val store = AdminNoticeRecipientKeyStore(storage)

    @Test
    fun `the same account asking again keeps the same 32-byte public key`() {
        val first = store.publicKeyFor("uid-alice")
        val again = store.publicKeyFor("uid-alice")

        assertEquals(32, first.size)
        assertArrayEquals(first, again)
    }

    @Test
    fun `another account signing in replaces the key, and nothing of the old one stays on disk`() {
        val alice = store.publicKeyFor("uid-alice")
        val aliceOnDisk = storage.all.values.toSet()

        val bob = store.publicKeyFor("uid-bob")

        assertFalse(alice.contentEquals(bob))
        assertEquals(emptySet<Any?>(), storage.all.values.toSet().intersect(aliceOnDisk))
    }

    @Test
    fun `agreement is X25519 of this device's key with the sender's ephemeral key (RFC 7748 6_1)`() {
        val store = AdminNoticeRecipientKeyStore(storage, newPrivateKey = { RFC7748_ALICE_PRIVATE.copyOf() })

        assertArrayEquals(RFC7748_ALICE_PUBLIC, store.publicKeyFor("uid-alice"))
        assertArrayEquals(RFC7748_SHARED, store.agree(RFC7748_BOB_PUBLIC))
    }

    @Test
    fun `before any sign-in there is no key, so no public key and nothing to agree with`() {
        assertNull(store.publicKey())
        assertNull(store.agree(RFC7748_BOB_PUBLIC))
    }

    @Test
    fun `the current public key is the one registered at the last sign-in`() {
        val alice = store.publicKeyFor("uid-alice")

        assertArrayEquals(alice, store.publicKey())
    }

    @Test
    fun `after a sign-out clears it nothing can be agreed and nothing stays on disk`() {
        store.publicKeyFor("uid-alice")

        store.clear()

        assertNull(store.publicKey())
        assertNull(store.agree(RFC7748_BOB_PUBLIC))
        assertEquals(emptyMap<String, Any?>(), storage.all)
    }

    @Test
    fun `the same account signing in again after a sign-out gets a new key`() {
        val before = store.publicKeyFor("uid-alice")
        store.clear()

        val after = store.publicKeyFor("uid-alice")

        assertFalse(before.contentEquals(after))
    }

    @Test
    fun `a key reopened after an app restart is the same key`() {
        val alice = store.publicKeyFor("uid-alice")
        val agreed = store.agree(RFC7748_BOB_PUBLIC)

        val reopened = AdminNoticeRecipientKeyStore(storage)

        assertArrayEquals(alice, reopened.publicKey())
        assertArrayEquals(alice, reopened.publicKeyFor("uid-alice"))
        assertArrayEquals(agreed, reopened.agree(RFC7748_BOB_PUBLIC))
    }

    @Test
    fun `an ephemeral key that is not 32 bytes agrees on nothing`() {
        store.publicKeyFor("uid-alice")

        assertNull(store.agree(ByteArray(31) { 9 }))
        assertNull(store.agree(ByteArray(33) { 9 }))
        assertNull(store.agree(ByteArray(0)))
    }

    @Test
    fun `a low-order ephemeral key, whose shared secret would be all zeros, agrees on nothing`() {
        store.publicKeyFor("uid-alice")

        // u = 0 and u = 1 are small-order points: X25519 with any private key gives all zeros.
        assertNull(store.agree(ByteArray(32)))
        assertNull(store.agree(ByteArray(32).also { it[0] = 1 }))
    }

    @Test
    fun `a corrupted key on disk reads as no key, and the next sign-in replaces it`() {
        val corruptions = listOf("not base64 at all!", Base64.getEncoder().encodeToString(ByteArray(31) { 5 }))
        for (garbage in corruptions) {
            store.publicKeyFor("uid-alice")
            val written = storage.all.keys
            storage.edit().apply { written.forEach { putString(it, garbage) } }.commit()

            assertNull(garbage, store.publicKey())
            assertNull(garbage, store.agree(RFC7748_BOB_PUBLIC))
            val replaced = store.publicKeyFor("uid-alice")
            assertArrayEquals(garbage, replaced, store.publicKey())
            store.clear()
        }
    }

    @Test
    fun `a new key that cannot be saved fails loudly, and the other account's key is gone all the same`() {
        val disk = FailingCommits(storage)
        val store = AdminNoticeRecipientKeyStore(disk)
        store.publicKeyFor("uid-alice")
        disk.failWrites = true

        assertThrows(IllegalStateException::class.java) { store.publicKeyFor("uid-bob") }

        assertNull(store.publicKey())
        assertNull(store.agree(RFC7748_BOB_PUBLIC))
    }

    @Test
    fun `a sign-out that cannot delete the key fails loudly`() {
        val disk = FailingCommits(storage)
        val store = AdminNoticeRecipientKeyStore(disk)
        store.publicKeyFor("uid-alice")
        disk.failRemovals = true

        assertThrows(IllegalStateException::class.java) { store.clear() }
    }

    /** [real], except that a commit with a write ([failWrites]) or a removal ([failRemovals]) writes nothing. */
    private class FailingCommits(private val real: SharedPreferences) : SharedPreferences by real {
        var failWrites = false
        var failRemovals = false

        override fun edit(): SharedPreferences.Editor = Editor(real.edit())

        private inner class Editor(private val editor: SharedPreferences.Editor) : SharedPreferences.Editor by editor {
            private var writes = false
            private var removals = false

            override fun putString(key: String?, value: String?) = apply { writes = true; editor.putString(key, value) }
            override fun remove(key: String?) = apply { removals = true; editor.remove(key) }
            override fun clear() = apply { removals = true; editor.clear() }
            override fun commit() = !(writes && failWrites) && !(removals && failRemovals) && editor.commit()
        }
    }

    private companion object {
        fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

        val RFC7748_ALICE_PRIVATE = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        val RFC7748_ALICE_PUBLIC = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        val RFC7748_BOB_PUBLIC = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        val RFC7748_SHARED = hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    }
}
