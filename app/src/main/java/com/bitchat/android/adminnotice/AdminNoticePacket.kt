package com.bitchat.android.adminnotice

import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.util.AppConstants
import com.bitchat.android.util.dataFromHexString
import com.bitchat.android.util.toHexString

/**
 * The 0x31 packet around an Admin Notice payload (docs/ADMIN_NOTICE_V1.md「外層封包」). It is
 * normalized: its fields follow from the payload alone, so every Gateway that injects the same
 * notice builds the same packet, with the same `PacketIdUtil` ID (ADR-0011).
 */
internal object AdminNoticePacket {

    /**
     * The packet a Gateway injects: version 1, TTL [AppConstants.MESSAGE_TTL_HOPS], senderID the
     * messageId, timestamp the issuedAt, the payload unchanged; no recipient, device signature,
     * severity or route. Compression is left to `BinaryProtocol`: the Administrators' signature
     * covers the decompressed payload.
     */
    fun outer(payload: AdminNoticePayload): BitchatPacket = BitchatPacket(
        version = 1u,
        type = MessageType.ADMIN_NOTICE.value,
        senderID = requireNotNull(payload.messageId.dataFromHexString()),
        recipientID = null,
        timestamp = payload.issuedAtMs.toULong(),
        payload = payload.wire,
        signature = null,
        ttl = AppConstants.MESSAGE_TTL_HOPS,
        route = null,
        severity = null
    )

    /** Step 3: the outer senderID is the notice's messageId and the outer timestamp its issuedAt. */
    fun matches(packet: BitchatPacket, payload: AdminNoticePayload): Boolean =
        packet.senderID.toHexString() == payload.messageId &&
            packet.timestamp == payload.issuedAtMs.toULong()
}
