package com.bitchat.android.adminnotice

import com.bitchat.android.adminnotice.TestAdminNotices.V1
import com.bitchat.android.adminnotice.TestAdminNotices.V2
import com.bitchat.android.adminnotice.TestAdminNotices.VECTOR_ISSUED_AT
import com.bitchat.android.protocol.BinaryProtocol
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.sync.PacketIdUtil
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

    @Test
    fun `the injection waits the delay drawn for it`() {
        inbox.attachInjector(mesh)
        injectionDelayMs = 15_000

        inbox.onBackendNotice(V1)

        assertEquals(listOf(15_000L), scheduler.delays)
    }

    @Test
    fun `the same notice heard over the mesh while waiting is not injected`() {
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)
        advance(3_000)

        inbox.onMeshPacket(TestAdminNotices.meshPacket(V1))
        advance(15_000)

        assertTrue(mesh.injected.isEmpty())
        assertEquals(0, scheduler.pending)
    }

    @Test
    fun `once injected, the notice is in the mesh and an echo of it is not relayed`() {
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)
        advance(7_000)

        val echo = inbox.onMeshPacket(TestAdminNotices.meshPacket(V1, ttl = 6u))

        assertEquals(AdminNoticeOutcome.Duplicate, echo)
        assertEquals(1, mesh.injected.size)
    }

    @Test
    fun `reading the notice from the backend again does not inject it twice`() {
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)
        advance(1_000)

        assertEquals(AdminNoticeOutcome.Duplicate, inbox.onBackendNotice(V1))
        advance(15_000)

        assertEquals(1, mesh.injected.size)
    }

    @Test
    fun `without a running mesh service the injection is dropped`() {
        inbox.onBackendNotice(V1)
        advance(7_000)
        inbox.attachInjector(mesh)
        advance(15_000)

        assertTrue(mesh.injected.isEmpty())
    }

    @Test
    fun `when the mesh service stops, every pending injection is cancelled`() {
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)
        inbox.onBackendNotice(TestAdminNotices.signed())

        inbox.detachInjector(mesh)
        inbox.attachInjector(mesh)
        advance(15_000)

        assertTrue(mesh.injected.isEmpty())
        assertEquals(0, scheduler.pending)
    }

    @Test
    fun `after the service restarts, the listener reading a cancelled notice again injects it, without presenting it again`() {
        val shown = mutableListOf<String>()
        val gateway = AdminNoticeInbox(
            adminKeys = TestAdminNotices.TEST_KEYS,
            presenter = object : AdminNoticePresenter {
                override fun present(notice: ReceivedAdminNotice) {
                    shown += notice.messageId
                }
            },
            nowMs = { now },
            injectionScheduler = scheduler,
            injectionDelayMs = { injectionDelayMs }
        )
        gateway.attachInjector(mesh)
        gateway.onBackendNotice(V1)
        gateway.detachInjector(mesh)

        gateway.attachInjector(mesh)
        assertEquals(AdminNoticeOutcome.Duplicate, gateway.onBackendNotice(V1))
        advance(7_000)

        assertEquals(1, mesh.injected.size)
        assertEquals(1, shown.size)
    }

    @Test
    fun `a dropped injection is scheduled again when the backend copy is read again`() {
        mesh.accepts = false
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)
        advance(7_000)

        mesh.accepts = true
        inbox.onBackendNotice(V1)
        advance(7_000)

        assertEquals(1, mesh.injected.size)
    }

    @Test
    fun `two Gateways injecting the same notice put the same packet on the mesh`() {
        val otherScheduler = ManualScheduler()
        val otherMesh = RecordingInjector()
        val otherGateway = AdminNoticeInbox(
            adminKeys = TestAdminNotices.TEST_KEYS,
            presenter = object : AdminNoticePresenter {
                override fun present(notice: ReceivedAdminNotice) = Unit
            },
            nowMs = { now },
            injectionScheduler = otherScheduler,
            injectionDelayMs = { 2_000L }
        )
        inbox.attachInjector(mesh)
        otherGateway.attachInjector(otherMesh)
        inbox.onBackendNotice(V2)
        advance(7_000)
        otherGateway.onBackendNotice(V2)
        otherScheduler.advance(2_000)

        val mine = mesh.injected.single()
        val theirs = otherMesh.injected.single()
        assertEquals(PacketIdUtil.computeIdHex(mine), PacketIdUtil.computeIdHex(theirs))
        assertArrayEquals(mine.toBinaryData(padding = false), theirs.toBinaryData(padding = false))
    }

    @Test
    fun `a node hearing the injected packet over the air verifies and relays it`() {
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)
        advance(7_000)

        val overTheAir = BitchatPacket.fromBinaryData(mesh.injected.single().toBinaryData()!!)!!

        assertTrue(node().onMeshPacket(overTheAir).relay)
    }

    @Test
    fun `a notice the protocol compresses on the air still verifies after decompression`() {
        val repetitive = TestAdminNotices.signed(body = "請往高處避難。".repeat(14).toByteArray(Charsets.UTF_8))
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(repetitive)
        advance(7_000)

        val onTheAir = mesh.injected.single().toBinaryData(padding = false)!!
        assertEquals(BinaryProtocol.Flags.IS_COMPRESSED.toInt(), onTheAir[11].toInt() and BinaryProtocol.Flags.IS_COMPRESSED.toInt())
        assertTrue(onTheAir.size < repetitive.size)

        assertTrue(node().onMeshPacket(BitchatPacket.fromBinaryData(onTheAir)!!).relay)
    }

    /** Another device, not a Gateway, hearing the mesh. */
    private fun node() = AdminNoticeInbox(
        adminKeys = TestAdminNotices.TEST_KEYS,
        presenter = object : AdminNoticePresenter {
            override fun present(notice: ReceivedAdminNotice) = Unit
        },
        nowMs = { now },
        injectionScheduler = ManualScheduler()
    )

    @Test
    fun `a replaced mesh service stopping late leaves its successor's injections alone`() {
        val replaced = RecordingInjector()
        inbox.attachInjector(replaced)
        inbox.attachInjector(mesh)
        inbox.onBackendNotice(V1)

        inbox.detachInjector(replaced)
        advance(7_000)

        assertEquals(1, mesh.injected.size)
        assertTrue(replaced.injected.isEmpty())
    }
}
