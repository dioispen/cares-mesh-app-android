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
    private val now = 1_700_000_001_000L
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
            "t_ms,ev,type,src,pts,ttl,len,peer,fanout,rssi,mode,n_links,batt,temp",
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
                "$now,RX,0x30,a1b2c3d4,1700000000123,6,$len,88990011,,,BALANCED,2,,",
                "$now,DUP,0x30,a1b2c3d4,1700000000123,6,$len,,,,BALANCED,2,,"
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
                "$now,TX,0x30,00112233,1700000000123,7,256,,3,,BALANCED,2,,",
                "$now,RELAY,0x30,a1b2c3d4,1700000000123,5,256,,1,,BALANCED,2,,"
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
                "$now,QFULL,0x30,a1b2c3d4,1700000000123,6,${data.size},88990011,,,BALANCED,2,,",
                "$now,QFULL,,,,,1,,,,BALANCED,2,,"
            ),
            rows
        )
    }

    @Test
    fun `link events name the neighbour, and LINK_UP its connection RSSI`() {
        recorder.onLinkUp(LINK_A, NEIGHBOUR)
        recorder.onLinkDown(LINK_A, NEIGHBOUR)

        assertEquals(
            listOf(
                "$now,LINK_UP,,,,,,88990011,,-61,BALANCED,2,,",
                "$now,LINK_DOWN,,,,,,88990011,,,BALANCED,2,,"
            ),
            rows
        )
    }

    @Test
    fun `STAT snapshots battery and every link, or one row when there is none`() {
        recorder.recordStat(BatteryReading(percent = 87, temperatureC = 31.46))
        probe.links = emptyList()
        probe.linkCount = 0
        recorder.recordStat(BatteryReading(percent = null, temperatureC = null))

        assertEquals(
            listOf(
                "$now,STAT,,,,,,88990011,,-61,BALANCED,2,87,31.5",
                "$now,STAT,,,,,,,,,BALANCED,2,87,31.5",
                "$now,STAT,,,,,,,,,BALANCED,0,,"
            ),
            rows
        )
    }

    @Test
    fun `context the mesh cannot give yet is left empty`() {
        probe.powerMode = null
        probe.linkCount = null

        recorder.onLinkDown(LINK_A, NEIGHBOUR)

        assertEquals(listOf("$now,LINK_DOWN,,,,,,88990011,,,,,,"), rows)
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

    private class FakeProbe : MeshProbe {
        var powerMode: String? = "BALANCED"
        var linkCount: Int? = 2
        var links = listOf(
            MeshProbe.Link(LINK_A, NEIGHBOUR, -61),
            MeshProbe.Link(LINK_B, null, null)
        )

        override fun myPeerID(): String = ME
        override fun powerMode(): String? = powerMode
        override fun linkCount(): Int? = linkCount
        override fun peerAt(address: String): String? = links.firstOrNull { it.address == address }?.peerID
        override fun rssiAt(address: String): Int? = links.firstOrNull { it.address == address }?.rssi
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
