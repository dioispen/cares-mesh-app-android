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
 * [rxCounter] 給現場計數畫面，自己送出的實驗 Health Report 寫出幾條鏈路則交給 [onExperimentTx]。
 *
 * 只在呼叫端的執行緒上組事件，寫檔交給 [sink]（[ExperimentLog] 的背景 writer）。
 */
class ExperimentEventRecorder(
    private val sink: (ExperimentEvent) -> Unit,
    private val probe: MeshProbe,
    private val rxCounter: ExperimentRxCounter,
    private val clock: () -> Long = System::currentTimeMillis,
    /** 本機發出的實驗 Health Report 已寫出：封包 timestamp 與寫出的鏈路數（發送器據此計數）。 */
    private val onExperimentTx: (pts: Long, fanout: Int) -> Unit = { _, _ -> }
) : ExperimentRecorder {

    private data class RssiSample(val rssi: Int, val atMs: Long)

    /** 每個鄰居（完整 peerID）最近一次記下的掃描 RSSI。 */
    private val scanRssi = HashMap<String, RssiSample>()

    override fun onReceived(packet: BitchatPacket, ingressAddress: String?) {
        val now = clock()
        emit(packetEvent(Kind.RX, now, packet, packet.bleLength(), peer = ingressAddress?.let(probe::peerAt)))
        experimentHandleOf(packet)?.let { rxCounter.record(it, now) }
    }

    override fun onDuplicate(packet: BitchatPacket, ingressAddress: String?) {
        emit(packetEvent(Kind.DUP, clock(), packet, packet.bleLength(), peer = ingressAddress?.let(probe::peerAt)))
    }

    override fun onBroadcastWritten(packet: BitchatPacket, wireBytes: Int, fanout: Int) {
        recordBroadcast(packet, wireBytes, fanout)
    }

    override fun onBroadcastDropped(packet: BitchatPacket) {
        recordBroadcast(packet, packet.bleLength(), fanout = 0)
    }

    private fun recordBroadcast(packet: BitchatPacket, len: Int?, fanout: Int) {
        val kind = if (packet.senderID.toHexString() == probe.myPeerID()) Kind.TX else Kind.RELAY
        emit(packetEvent(kind, clock(), packet, len, fanout = fanout))
        if (kind == Kind.TX && experimentHandleOf(packet) != null) {
            onExperimentTx(packet.timestamp.toLong(), fanout)
        }
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
        val now = clock()
        emit(ExperimentEvent(now, Kind.LINK_UP, peer = id8(peerID), rssi = latestRssi(peerID, now)))
    }

    override fun onLinkDown(deviceAddress: String, peerID: String) {
        emit(ExperimentEvent(clock(), Kind.LINK_DOWN, peer = id8(peerID)))
    }

    /**
     * 每個鄰居每 [RSSI_SAMPLE_INTERVAL_MS] 最多記一列，掃描結果多的時候不會把 CSV 灌爆；30 s 內
     * 仍有足夠的樣本取中位數。沒有 peerID 的廣播算給同位址的直連；都認不出是誰就不記。
     */
    override fun onScanRssi(peerID: String?, deviceAddress: String, rssi: Int) {
        val peer = peerID ?: probe.peerAt(deviceAddress) ?: return
        val now = clock()
        synchronized(scanRssi) {
            val last = scanRssi[peer]
            if (last != null && now - last.atMs < RSSI_SAMPLE_INTERVAL_MS) return
            scanRssi[peer] = RssiSample(rssi, now)
        }
        emit(ExperimentEvent(now, Kind.RSSI, peer = id8(peer), rssi = rssi))
    }

    /** `STAT`：每條直連一列（鄰居與它最近的 RSSI），沒有直連時一列；電量與溫度每列相同。 */
    fun recordStat(battery: BatteryReading) {
        val now = clock()
        val links = probe.links().ifEmpty { listOf(null) }
        links.forEach { link ->
            emit(
                ExperimentEvent(
                    now,
                    Kind.STAT,
                    peer = link?.peerID?.let(::id8),
                    rssi = link?.peerID?.let { latestRssi(it, now) },
                    batt = battery.percent,
                    temp = battery.temperatureC
                )
            )
        }
    }

    /** [peer] 在 [RSSI_FRESH_MS] 內最新的掃描 RSSI；太舊或沒有時為 null。 */
    private fun latestRssi(peer: String, now: Long): Int? = synchronized(scanRssi) {
        scanRssi[peer]?.takeIf { now - it.atMs <= RSSI_FRESH_MS }?.rssi
    }

    private fun emit(event: ExperimentEvent) {
        sink(event.copy(mode = probe.powerMode(), nLinks = probe.linkCount(), sysSaver = probe.systemPowerSave()))
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

    companion object {
        /** 同一個鄰居兩列 `RSSI` 之間至少隔多久。 */
        const val RSSI_SAMPLE_INTERVAL_MS = 1_000L

        /** `LINK_UP`／`STAT` 採用的掃描 RSSI 最多可以多舊。 */
        const val RSSI_FRESH_MS = 60_000L
    }
}
