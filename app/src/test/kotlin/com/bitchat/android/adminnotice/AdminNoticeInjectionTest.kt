package com.bitchat.android.adminnotice

import com.bitchat.android.adminnotice.TestAdminNotices.V1
import com.bitchat.android.adminnotice.TestAdminNotices.VECTOR_ISSUED_AT
import com.bitchat.android.protocol.MessageType
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Gateway's injection into the mesh (#137,「Gateway：從 Firestore 注入 mesh」), through the Inbox's
 * ports only: notices go in from the backend and the mesh, and the test watches what the mesh
 * service is asked to inject and when. The delay, the scheduler and the clock are all fakes.
 */
class AdminNoticeInjectionTest {

    private var now = VECTOR_ISSUED_AT + 60_000L
    private val scheduler = ManualScheduler()
    private val mesh = RecordingInjector()
    private var injectionDelayMs = 7_000L

    private val inbox = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) = Unit
        },
        nowMs = { now },
        injectionScheduler = scheduler,
        injectionDelayMs = { injectionDelayMs }
    )

    private fun advance(ms: Long) {
        now += ms
        scheduler.advance(ms)
    }

    @Test
    fun `a backend notice is injected as the normalized packet once its delay ends`() {
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)

        advance(6_999)
        assertTrue(mesh.injected.isEmpty())
        advance(1)

        val packet = mesh.injected.single()
        assertEquals(1, packet.version.toInt())
        assertEquals(MessageType.ADMIN_NOTICE.value, packet.type)
        assertEquals(7, packet.ttl.toInt())
        assertEquals(VECTOR_ISSUED_AT, packet.timestamp.toLong())
        assertArrayEquals(hex("a1b2c3d4e5f60718"), packet.senderID)
        assertNull(packet.recipientID)
        assertNull(packet.signature)
        assertNull(packet.route)
        assertNull(packet.severity)
        assertArrayEquals(V1, packet.payload)
    }
}
