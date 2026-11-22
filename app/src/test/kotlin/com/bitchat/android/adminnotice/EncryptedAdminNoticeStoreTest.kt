package com.bitchat.android.adminnotice

import android.content.Context
import android.content.SharedPreferences
import com.bitchat.android.testsupport.TestAdminNotices.VECTOR_ISSUED_AT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.util.UUID

/**
 * 收件端的本機儲存 as the notice list (#142) reads it: read state, newest first, and kept until
 * 7 days after expiresAt. Plain SharedPreferences stand in for the encrypted file, which
 * [LocalAdminNoticePresenterTest] covers; the clock is the test's.
 */
@RunWith(RobolectricTestRunner::class)
class EncryptedAdminNoticeStoreTest {

    private val prefs: SharedPreferences = RuntimeEnvironment.getApplication()
        .getSharedPreferences("admin-notice-store-${UUID.randomUUID()}", Context.MODE_PRIVATE)
    private var now = VECTOR_ISSUED_AT + 60_000L

    /** What one process opens; a second call is the App after a restart, over the same file. */
    private fun openStore() = EncryptedAdminNoticeStore(openPrefs = { prefs }, nowMs = { now })

    private val store = openStore()

    private fun notice(
        messageId: String,
        issuedAtMs: Long = VECTOR_ISSUED_AT,
        expiresAtMs: Long = issuedAtMs + HOUR,
        status: AdminNoticeStatus = AdminNoticeStatus.ACTIVE,
        replacedBy: String? = null
    ) = StoredAdminNotice(
        messageId = messageId,
        kind = AdminNoticeKind.BROADCAST,
        level = AdminNoticeLevel.IMPORTANT,
        issuedAtMs = issuedAtMs,
        expiresAtMs = expiresAtMs,
        replaces = null,
        content = "收容所已開放",
        status = status,
        receivedAtMs = now,
        replacedBy = replacedBy
    )

    @Test
    fun `a stored notice is unread until it is marked read`() {
        store.insertIfAbsent(notice("1111111111111111"))
        assertFalse(store.all().single().isRead)

        now += 5 * 60_000L
        val read = store.markRead("1111111111111111")

        assertEquals(now, read?.readAtMs)
        assertTrue(store.all().single().isRead)
        assertEquals(now, store.all().single().readAtMs)
    }

    @Test
    fun `a notice is read once, and an unknown one not at all`() {
        store.insertIfAbsent(notice("1111111111111111"))
        val first = store.markRead("1111111111111111")

        now += 60_000L
        assertNull("already read", store.markRead("1111111111111111"))
        assertNull("never stored", store.markRead("2222222222222222"))
        assertEquals("the first reading's time is kept", first?.readAtMs, store.all().single().readAtMs)
    }

    @Test
    fun `read state, status and the correcting notice survive an App restart`() {
        store.insertIfAbsent(notice("1111111111111111"))
        store.insertIfAbsent(notice("2222222222222222", status = AdminNoticeStatus.CORRECTED, replacedBy = "3333333333333333"))
        store.insertIfAbsent(notice("4444444444444444", status = AdminNoticeStatus.WITHDRAWN))
        store.markRead("1111111111111111")

        val restarted = openStore().all().associateBy { it.messageId }

        assertTrue(restarted.getValue("1111111111111111").isRead)
        assertFalse(restarted.getValue("2222222222222222").isRead)
        assertEquals(AdminNoticeStatus.CORRECTED, restarted.getValue("2222222222222222").status)
        assertEquals("3333333333333333", restarted.getValue("2222222222222222").replacedBy)
        assertEquals(AdminNoticeStatus.WITHDRAWN, restarted.getValue("4444444444444444").status)
    }

    // ── 撤回與取代（#139）───────────────────────────────────────────────────

    @Test
    fun `a corrected notice stays listed without its content and names the notice that corrected it`() {
        store.insertIfAbsent(notice("1111111111111111"))
        var changes = 0
        store.addChangeListener { changes++ }

        val corrected = store.markCorrected("1111111111111111", correctedBy = "2222222222222222")

        val stored = store.all().single()
        assertEquals(stored, corrected)
        assertEquals(AdminNoticeStatus.CORRECTED, stored.status)
        assertEquals("2222222222222222", stored.replacedBy)
        assertEquals("", stored.content)
        assertEquals(1, changes)
    }

    @Test
    fun `a withdrawn notice stays listed without its content`() {
        store.insertIfAbsent(notice("1111111111111111"))
        var changes = 0
        store.addChangeListener { changes++ }

        val withdrawn = store.markWithdrawn("1111111111111111")

        val stored = store.all().single()
        assertEquals(stored, withdrawn)
        assertEquals(AdminNoticeStatus.WITHDRAWN, stored.status)
        assertNull(stored.replacedBy)
        assertEquals("", stored.content)
        assertEquals(1, changes)
    }

    @Test
    fun `only an active notice can be corrected, and anything but a withdrawn one withdrawn`() {
        store.insertIfAbsent(notice("1111111111111111"))
        store.markCorrected("1111111111111111", correctedBy = "2222222222222222")
        store.insertIfAbsent(notice("2222222222222222", issuedAtMs = VECTOR_ISSUED_AT + 60_000L))
        var changes = 0
        store.addChangeListener { changes++ }

        assertNull("a second correction does not move the link", store.markCorrected("1111111111111111", "3333333333333333"))
        assertEquals(AdminNoticeStatus.WITHDRAWN, store.markWithdrawn("1111111111111111")?.status)
        assertNull("already withdrawn", store.markWithdrawn("1111111111111111"))
        assertNull("a withdrawn notice is not corrected", store.markCorrected("1111111111111111", "3333333333333333"))

        val stored = store.all().single { it.messageId == "1111111111111111" }
        assertEquals(AdminNoticeStatus.WITHDRAWN, stored.status)
        assertEquals("it was corrected before it was withdrawn", "2222222222222222", stored.replacedBy)
        assertEquals("one change: the withdrawal", 1, changes)
    }

    @Test
    fun `a correction moves the link while the one it points to is not listed here`() {
        // A targeted correction split into several notices, or sent to other devices: this device
        // may hear first one it cannot open, and only later the one it can.
        store.insertIfAbsent(notice("1111111111111111"))
        store.markCorrected("1111111111111111", correctedBy = "2222222222222222")

        assertEquals("3333333333333333", store.markCorrected("1111111111111111", "3333333333333333")?.replacedBy)
        store.insertIfAbsent(notice("3333333333333333", issuedAtMs = VECTOR_ISSUED_AT + 60_000L))
        assertNull("now it points to one listed here", store.markCorrected("1111111111111111", "4444444444444444"))

        assertEquals("3333333333333333", store.all().single { it.messageId == "1111111111111111" }.replacedBy)
    }

    @Test
    fun `marking a notice that is not stored changes nothing`() {
        var changes = 0
        store.addChangeListener { changes++ }

        assertNull(store.markCorrected("1111111111111111", correctedBy = "2222222222222222"))
        assertNull(store.markWithdrawn("1111111111111111"))
        assertEquals(emptyList<StoredAdminNotice>(), store.all())
        assertEquals(0, changes)
    }

    @Test
    fun `a withdrawal survives a restart, and storing the notice again does not bring it back`() {
        store.insertIfAbsent(notice("1111111111111111"))
        store.markRead("1111111111111111")
        store.markWithdrawn("1111111111111111")

        val restarted = openStore()
        val insertedAgain = restarted.insertIfAbsent(notice("1111111111111111"))

        assertFalse(insertedAgain)
        val stored = restarted.all().single()
        assertEquals(AdminNoticeStatus.WITHDRAWN, stored.status)
        assertEquals("", stored.content)
        assertTrue("read state is kept", stored.isRead)
    }

    @Test
    fun `notices are listed newest first`() {
        store.insertIfAbsent(notice("1111111111111111", issuedAtMs = VECTOR_ISSUED_AT))
        store.insertIfAbsent(notice("3333333333333333", issuedAtMs = VECTOR_ISSUED_AT + 2 * 60_000L))
        store.insertIfAbsent(notice("2222222222222222", issuedAtMs = VECTOR_ISSUED_AT + 60_000L))

        assertEquals(
            listOf("3333333333333333", "2222222222222222", "1111111111111111"),
            store.all().map { it.messageId }
        )
    }

    @Test
    fun `an expired notice is kept until 7 days after expiresAt, then disappears`() {
        val expiresAt = VECTOR_ISSUED_AT + HOUR
        store.insertIfAbsent(notice("1111111111111111", expiresAtMs = expiresAt))

        now = expiresAt + SEVEN_DAYS
        assertEquals("still listed (as 已過期) on the last day", 1, store.all().size)

        now += 1
        assertEquals(emptyList<StoredAdminNotice>(), store.all())
        assertNull("nothing left to mark read", store.markRead("1111111111111111"))
    }

    @Test
    fun `a notice past its retention is deleted from the file, not only hidden`() {
        val expiresAt = VECTOR_ISSUED_AT + HOUR
        store.insertIfAbsent(notice("1111111111111111", expiresAtMs = expiresAt))
        now = expiresAt + SEVEN_DAYS + 1

        store.insertIfAbsent(notice("2222222222222222", issuedAtMs = now, expiresAtMs = now + HOUR))

        assertEquals(setOf("2222222222222222"), prefs.all.keys)
    }

    @Test
    fun `listeners hear of a new notice and of a first reading, nothing else`() {
        var changes = 0
        store.addChangeListener { changes++ }

        store.insertIfAbsent(notice("1111111111111111"))
        assertEquals("stored", 1, changes)
        store.insertIfAbsent(notice("1111111111111111"))
        assertEquals("already stored", 1, changes)
        store.markRead("1111111111111111")
        assertEquals("read", 2, changes)
        store.markRead("1111111111111111")
        store.markRead("2222222222222222")
        store.all()
        assertEquals("nothing changed", 2, changes)
    }

    @Test
    fun `a removed listener hears nothing more`() {
        var changes = 0
        val listener = AdminNoticeChangeListener { changes++ }
        store.addChangeListener(listener)
        store.removeChangeListener(listener)

        store.insertIfAbsent(notice("1111111111111111"))

        assertEquals(0, changes)
    }

    @Test
    fun `a listener may read the store it hears from`() {
        val seen = mutableListOf<List<String>>()
        store.addChangeListener { seen += store.all().map { it.messageId } }

        store.insertIfAbsent(notice("1111111111111111"))

        assertEquals(listOf(listOf("1111111111111111")), seen)
    }

    private companion object {
        const val HOUR = 3_600_000L
        const val SEVEN_DAYS = 7 * 24 * HOUR
    }
}
