package com.bitchat.android.testsupport

import com.bitchat.android.experiment.ExperimentRecorder
import com.bitchat.android.protocol.BitchatPacket

/** Records the experiment events an insertion point reports, as `EV:detail` strings in order. */
internal class RecordingExperimentRecorder : ExperimentRecorder {
    val events = mutableListOf<String>()

    override fun onReceived(packet: BitchatPacket, ingressAddress: String?) {
        events += "RX:${packet.timestamp}:$ingressAddress"
    }

    override fun onDuplicate(packet: BitchatPacket, ingressAddress: String?) {
        events += "DUP:${packet.timestamp}:$ingressAddress"
    }

    override fun onBroadcastWritten(packet: BitchatPacket, wireBytes: Int, fanout: Int) {
        events += "WRITTEN:${packet.timestamp}:$fanout"
    }

    override fun onSendQueueFull(deviceAddress: String, data: ByteArray) {
        events += "QFULL:$deviceAddress"
    }

    override fun onLinkUp(deviceAddress: String, peerID: String) {
        events += "LINK_UP:$deviceAddress:$peerID"
    }

    override fun onLinkDown(deviceAddress: String, peerID: String) {
        events += "LINK_DOWN:$deviceAddress:$peerID"
    }

    override fun onScanRssi(peerID: String?, deviceAddress: String, rssi: Int) {
        events += "RSSI:$peerID:$deviceAddress:$rssi"
    }
}
