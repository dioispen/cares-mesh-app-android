package com.bitchat.android.experiment

import com.bitchat.android.mesh.BLEPacketPaddingPolicy
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.HealthStatus
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.service.HealthReportBroadcast
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Every event kind becomes one CSV row with the columns in the order the analysis expects, and
 * `(src, pts)` always identifies the packet the same way on sender and receiver (#70).
 */
class ExperimentEventRecorderTest {
    private var now = 1_700_000_001_000L
    private val rows = mutableListOf<String>()
    private val probe = FakeProbe()
    private val counter = ExperimentRxCounter { now }
    private val recorder = ExperimentEventRecorder(
        sink = { rows += it.toCsvRow() },
        probe = probe,
        rxCounter = counter,
        clock = { now }
    )

    private fun healthReport(sender: String, handle: String = "abcdef012345", ttl: UByte = 6u): BitchatPacket {
        val payload = HealthReportPayload(handle, HealthStatus.SAFE, "", 1_700_000_000_000L).encode()
        return HealthReportBroadcast.packet(sender, payload, ttl, timestamp = 1_700_000_000_123L)
    }

    private fun BitchatPacket.bleLength(): Int =
        toBinaryData(padding = BLEPacketPaddingPolicy.shouldPadForBLE(type))!!.size

    @Test
    fun `the header names the columns in row order`() {
        assertEquals(
            "t_ms,ev,type,src,pts,ttl,len,peer,fanout,rssi,mode,n_links,batt,temp,sys_saver",
            ExperimentEvent.CSV_HEADER
        )
    }

    @Test
    fun `RX and DUP carry the packet identity and the previous hop`() {
        val packet = healthReport(OTHER)

        recorder.onReceived(packet, LINK_A)
        recorder.onDuplicate(packet, LINK_B)

        val len = packet.bleLength()
        assertEquals(
            listOf(
                "$now,RX,0x30,a1b2c3d4,1700000000123,6,$len,88990011,,,BALANCED,2,,,0",
                "$now,DUP,0x30,a1b2c3d4,1700000000123,6,$len,,,,BALANCED,2,,,0"
            ),
            rows
        )
    }

    @Test
    fun `a write is TX when we sent the packet and RELAY otherwise`() {
        recorder.onBroadcastWritten(healthReport(ME, ttl = 7u), wireBytes = 256, fanout = 3)
        recorder.onBroadcastWritten(healthReport(OTHER, ttl = 5u), wireBytes = 256, fanout = 1)

        assertEquals(
            listOf(
                "$now,TX,0x30,00112233,1700000000123,7,256,,3,,BALANCED,2,,,0",
                "$now,RELAY,0x30,a1b2c3d4,1700000000123,5,256,,1,,BALANCED,2,,,0"
            ),
            rows
        )
    }

    @Test
    fun `a full queue identifies the rejected packet from its wire bytes`() {
        val data = healthReport(OTHER).toBinaryData(padding = true)!!

        recorder.onSendQueueFull(LINK_A, data)
        recorder.onSendQueueFull(LINK_B, byteArrayOf(0x7F))

        assertEquals(
            listOf(
                "$now,QFULL,0x30,a1b2c3d4,1700000000123,6,${data.size},88990011,,,BALANCED,2,,,0",
                "$now,QFULL,,,,,1,,,,BALANCED,2,,,0"
            ),
            rows
        )
    }

    @Test
    fun `link events name the neighbour, and LINK_UP its latest scanned RSSI`() {
        recorder.onScanRssi(NEIGHBOUR, LINK_A, -61)
        rows.clear()

        recorder.onLinkUp(LINK_A, NEIGHBOUR)
        recorder.onLinkDown(LINK_A, NEIGHBOUR)

        assertEquals(
            listOf(
                "$now,LINK_UP,,,,,,88990011,,-61,BALANCED,2,,,0",
                "$now,LINK_DOWN,,,,,,88990011,,,BALANCED,2,,,0"
            ),
            rows
        )
    }

    @Test
    fun `a neighbour's advertisements are sampled as RSSI rows at most once a second`() {
        recorder.onScanRssi(NEIGHBOUR, LINK_A, -70)
        now += 500
        recorder.onScanRssi(NEIGHBOUR, LINK_A, -71)
        now += 500
        recorder.onScanRssi(NEIGHBOUR, LINK_A, -72)
        recorder.onScanRssi(OTHER, "AA:00:00:00:00:09", -80)

        assertEquals(
            listOf(
                "${now - 1_000},RSSI,,,,,,88990011,,-70,BALANCED,2,,,0",
                "$now,RSSI,,,,,,88990011,,-72,BALANCED,2,,,0",
                "$now,RSSI,,,,,,a1b2c3d4,,-80,BALANCED,2,,,0"
            ),
            rows
        )
    }

    @Test
    fun `an advertisement without a peerID is credited to its link's peer, or dropped when unknown`() {
        recorder.onScanRssi(null, LINK_A, -65)
        recorder.onScanRssi(null, "AA:00:00:00:00:09", -90)

        assertEquals(listOf("$now,RSSI,,,,,,88990011,,-65,BALANCED,2,,,0"), rows)
    }

    @Test
    fun `a link with no advertisement heard in the last minute has no RSSI`() {
        recorder.onScanRssi(NEIGHBOUR, LINK_A, -61)
        now += 60_001
        rows.clear()

        recorder.onLinkUp(LINK_A, NEIGHBOUR)

        assertEquals(listOf("$now,LINK_UP,,,,,,88990011,,,BALANCED,2,,,0"), rows)
    }

    @Test
    fun `STAT snapshots battery and every link, or one row when there is none`() {
        recorder.onScanRssi(NEIGHBOUR, LINK_A, -61)
        rows.clear()
        recorder.recordStat(BatteryReading(percent = 87, temperatureC = 31.46))
        probe.links = emptyList()
        probe.linkCount = 0
        recorder.recordStat(BatteryReading(percent = null, temperatureC = null))

        assertEquals(
            listOf(
                "$now,STAT,,,,,,88990011,,-61,BALANCED,2,87,31.5,0",
                "$now,STAT,,,,,,,,,BALANCED,2,87,31.5,0",
                "$now,STAT,,,,,,,,,BALANCED,0,,,0"
            ),
            rows
        )
    }

    @Test
    fun `context the mesh cannot give yet is left empty`() {
        probe.powerMode = null
        probe.linkCount = null
        probe.systemPowerSave = null

        recorder.onLinkDown(LINK_A, NEIGHBOUR)

        assertEquals(listOf("$now,LINK_DOWN,,,,,,88990011,,,,,,,"), rows)
    }

    @Test
    fun `only first receptions of experiment Health Reports reach the live counter`() {
        val experiment = healthReport(OTHER, handle = "ee0000000003")
        recorder.onReceived(experiment, LINK_A)
        recorder.onDuplicate(experiment, LINK_B)
        recorder.onReceived(healthReport(OTHER, handle = "abcdef012345"), LINK_A)
        recorder.onReceived(
            BitchatPacket(type = MessageType.MESSAGE.value, ttl = 7u, senderID = OTHER, payload = byteArrayOf(1)),
            LINK_A
        )

        assertEquals(mapOf("ee0000000003" to 1), counter.countsWithin(20_000))
    }

    @Test
    fun `every row says whether the system battery saver was on`() {
        probe.systemPowerSave = true

        recorder.onLinkDown(LINK_A, NEIGHBOUR)

        assertEquals(listOf("$now,LINK_DOWN,,,,,,88990011,,,BALANCED,2,,,1"), rows)
    }

    @Test
    fun `our experiment Health Report writes are reported with their fanout`() {
        val written = mutableListOf<Pair<Long, Int>>()
        val reporting = ExperimentEventRecorder(
            sink = { },
            probe = probe,
            rxCounter = counter,
            clock = { now },
            onExperimentTx = { pts, fanout -> written += pts to fanout }
        )

        reporting.onBroadcastWritten(healthReport(ME, handle = "ee0000000003", ttl = 7u), wireBytes = 256, fanout = 0)
        reporting.onBroadcastWritten(healthReport(ME, handle = "abcdef012345", ttl = 7u), wireBytes = 256, fanout = 2)
        reporting.onBroadcastWritten(healthReport(OTHER, handle = "ee0000000004", ttl = 6u), wireBytes = 256, fanout = 2)

        assertEquals(listOf(1_700_000_000_123L to 0), written)
    }

    private class FakeProbe : MeshProbe {
        var powerMode: String? = "BALANCED"
        var linkCount: Int? = 2
        var systemPowerSave: Boolean? = false
        var links = listOf(
            MeshProbe.Link(LINK_A, NEIGHBOUR),
            MeshProbe.Link(LINK_B, null)
        )

        override fun myPeerID(): String = ME
        override fun powerMode(): String? = powerMode
        override fun linkCount(): Int? = linkCount
        override fun systemPowerSave(): Boolean? = systemPowerSave
        override fun peerAt(address: String): String? = links.firstOrNull { it.address == address }?.peerID
        override fun links(): List<MeshProbe.Link> = links
    }

    private companion object {
        const val ME = "0011223344556677"
        const val OTHER = "a1b2c3d4e5f60718"
        const val NEIGHBOUR = "8899001122334455"
        const val LINK_A = "AA:00:00:00:00:01"
        const val LINK_B = "AA:00:00:00:00:02"
    }
}
