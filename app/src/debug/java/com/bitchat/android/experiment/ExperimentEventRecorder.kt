package com.bitchat.android.experiment

import com.bitchat.android.experiment.ExperimentEvent.Companion.id8
import com.bitchat.android.experiment.ExperimentEvent.Kind
import com.bitchat.android.mesh.BLEPacketPaddingPolicy
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.util.toHexString

/**
 * debug build 的 [ExperimentRecorder]（#70）：把插入點交來的原始資料補上 mesh 現況（上一跳 peer、
 * 電源模式、直連數），組成 [ExperimentEvent]（`exp.csv` 的一列）交給 [sink]；收到的實驗 Health Report 另外記進
 * [rxCounter] 給現場計數畫面。
 *
 * 只在呼叫端的執行緒上組事件，寫檔交給 [sink]（[ExperimentLog] 的背景 writer）。
 */
class ExperimentEventRecorder(
    private val sink: (ExperimentEvent) -> Unit,
    private val probe: MeshProbe,
    private val rxCounter: ExperimentRxCounter,
    private val clock: () -> Long = System::currentTimeMillis
) : ExperimentRecorder {

    override fun onReceived(packet: BitchatPacket, ingressAddress: String?) {
        val now = clock()
        emit(packetEvent(Kind.RX, now, packet, packet.bleLength(), peer = ingressAddress?.let(probe::peerAt)))
        experimentHandleOf(packet)?.let { rxCounter.record(it, now) }
    }

    override fun onDuplicate(packet: BitchatPacket, ingressAddress: String?) {
        emit(packetEvent(Kind.DUP, clock(), packet, packet.bleLength(), peer = ingressAddress?.let(probe::peerAt)))
    }

    override fun onBroadcastWritten(packet: BitchatPacket, wireBytes: Int, fanout: Int) {
        val kind = if (packet.senderID.toHexString() == probe.myPeerID()) Kind.TX else Kind.RELAY
        emit(packetEvent(kind, clock(), packet, wireBytes, fanout = fanout))
    }

    override fun onSendQueueFull(deviceAddress: String, data: ByteArray) {
        val now = clock()
        val peer = probe.peerAt(deviceAddress)
        val packet = BitchatPacket.fromBinaryData(data)
        emit(
            if (packet != null) {
                packetEvent(Kind.QFULL, now, packet, data.size, peer = peer)
            } else {
                ExperimentEvent(now, Kind.QFULL, len = data.size, peer = peer?.let(::id8))
            }
        )
    }

    override fun onLinkUp(deviceAddress: String, peerID: String) {
        emit(ExperimentEvent(clock(), Kind.LINK_UP, peer = id8(peerID), rssi = probe.rssiAt(deviceAddress)))
    }

    override fun onLinkDown(deviceAddress: String, peerID: String) {
        emit(ExperimentEvent(clock(), Kind.LINK_DOWN, peer = id8(peerID)))
    }

    /** `STAT`：每條直連一列（鄰居與它的 RSSI），沒有直連時一列；電量與溫度每列相同。 */
    fun recordStat(battery: BatteryReading) {
        val now = clock()
        val links = probe.links().ifEmpty { listOf(null) }
        links.forEach { link ->
            emit(
                ExperimentEvent(
                    now,
                    Kind.STAT,
                    peer = link?.peerID?.let(::id8),
                    rssi = link?.rssi,
                    batt = battery.percent,
                    temp = battery.temperatureC
                )
            )
        }
    }

    private fun emit(event: ExperimentEvent) {
        sink(event.copy(mode = probe.powerMode(), nLinks = probe.linkCount()))
    }

    private fun packetEvent(
        kind: Kind,
        now: Long,
        packet: BitchatPacket,
        len: Int?,
        peer: String? = null,
        fanout: Int? = null
    ) = ExperimentEvent(
        tMs = now,
        ev = kind,
        type = packet.type.toInt(),
        src = id8(packet.senderID.toHexString()),
        pts = packet.timestamp.toLong(),
        ttl = packet.ttl.toInt(),
        len = len,
        peer = peer?.let(::id8),
        fanout = fanout
    )

    /** 以 BLE 送出時的大小（含 padding 策略）；收到的封包已解碼，只能重新編碼量。 */
    private fun BitchatPacket.bleLength(): Int? =
        toBinaryData(padding = BLEPacketPaddingPolicy.shouldPadForBLE(type))?.size

    /**
     * 實驗發送器送的 Health Report 的 handle。這裡還在 MessageHandler 剝掉 content tag 之前，
     * 所以 `payload[0]` 是 [BroadcastContentTag]。
     */
    private fun experimentHandleOf(packet: BitchatPacket): String? {
        if (packet.type != MessageType.HEALTH_REPORT.value) return null
        val payload = packet.payload
        if (payload.isEmpty() || payload[0] != BroadcastContentTag.HEALTH_REPORT.value) return null
        val handle = HealthReportPayload.decode(payload.copyOfRange(1, payload.size))?.reporterHandle
        return handle?.takeIf(ExperimentHandles::isExperimentHandle)
    }
}
