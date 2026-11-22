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
     * Whether a FRAGMENT is relayed as it arrives. A 0x31's is not: only the Inbox can tell a
     * forged notice, and it sees one only once every fragment is in, so a relay that passed the
     * fragments on would flood a forgery before anyone checked it. The notice goes on as a whole,
     * once reassembled and accepted ([reassembled]), and the transport fragments it again.
     * Fragments of every other type are relayed as they arrive.
     */
    fun relaysFragment(fragment: BitchatPacket): Boolean = !carriesAdminNotice(fragment)

    /**
     * A reassembled packet as PacketProcessor goes on to handle it. FragmentManager zeroes the TTL
     * of every reassembled packet, because its fragments have been relayed already. A 0x31's have
     * not ([relaysFragment]): a 0x31 reassembled from fragments labelled 0x31 carries the TTL of the
     * fragment that completed it, so the Inbox and the relay rules take it like a 0x31 that arrived
     * whole — relayed once, normalized, one hop down. A sender fragments a packet all at once, so
     * its fragments share one TTL; they differ only when old-version relays carried them along
     * different paths. A sync reply's fragments have TTL 0, and so does the notice.
     *
     * Anything else keeps TTL 0: a set labelled 0x31 that reassembles to another type goes no
     * further, and a 0x31 inside fragments labelled otherwise, relayed as they arrived, is not
     * relayed a second time.
     */
    fun reassembled(packet: BitchatPacket, completedBy: BitchatPacket): BitchatPacket =
        if (packet.type == MessageType.ADMIN_NOTICE.value && !relaysFragment(completedBy)) {
            packet.copy(ttl = completedBy.ttl)
        } else {
            packet
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
