package com.bitchat.android.mesh

import com.bitchat.android.model.FragmentPayload
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType

/**
 * The mesh's view of ADMIN_NOTICE (0x31) packets (ADR-0011, docs/ADMIN_NOTICE_V1.md). Their senderID
 * is the notice's messageId, not a peer, so whatever treats a senderID as a peer — packet actors,
 * last-seen, the debug screen's per-peer counts, the field-experiment log — leaves them out. Their
 * trust comes from the Administrators' signature inside the payload, which `adminnotice/` checks.
 */
object AdminNoticeTraffic {

    /** A 0x31 packet, or a fragment of one: either way its senderID is a messageId. */
    fun carriesAdminNotice(packet: BitchatPacket): Boolean = when (packet.type) {
        MessageType.ADMIN_NOTICE.value -> true
        MessageType.FRAGMENT.value ->
            packet.payload.size >= FragmentPayload.HEADER_SIZE &&
                packet.payload[ORIGINAL_TYPE_OFFSET] == MessageType.ADMIN_NOTICE.value.toByte()
        else -> false
    }

    /**
     * The copy of a verified 0x31 a relay passes on: the normalized outer packet (「外層封包」),
     * whatever recipient, device signature, route or severity a sender added. None of these is in
     * the packet ID, so a copy carrying them is the same packet to the dedup and the Inbox accepts
     * it; relaying them would let that sender stop the notice at a chosen recipient or steer it
     * down a chosen route. TTL and the received payload encoding stay as they are.
     */
    fun normalizedForRelay(packet: BitchatPacket): BitchatPacket =
        packet.copy(version = 1u, recipientID = null, signature = null, route = null, severity = null)

    /** FragmentPayload: fragmentID (8) ‖ index (2) ‖ total (2) ‖ originalType (1) ‖ data. */
    private const val ORIGINAL_TYPE_OFFSET = FragmentPayload.HEADER_SIZE - 1
}
