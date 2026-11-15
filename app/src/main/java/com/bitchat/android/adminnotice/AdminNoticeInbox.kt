package com.bitchat.android.adminnotice

/**
 * AdminNoticeInbox（docs/ADMIN_NOTICE_V1.md「處理規則」）：every Admin Notice this device receives
 * goes through here, and is trusted only by an Administrator's signature (ADR-0011), never by the
 * Gateway or backend copy it came through.
 *
 * Inputs: [onBackendNotice] (the Gateway's Firestore listener, #136). The mesh's 0x31 packets join
 * in #137 through the same checks. Outputs go only to injected ports — today [presenter]; injection
 * (#137), the sync set (#138), the recipient key (#141) and receipts (#143) come as further ports —
 * and the clock is injected too, so every rule runs in a JVM test. Firebase-free and Android-free.
 *
 * Calls are serialised on this object's lock and return a decision at once, so the mesh can decide
 * whether to relay a packet while handling it. The dedup table is memory only: after an App restart
 * a notice is processed as new, and [presenter]'s store keeps it from notifying twice.
 */
class AdminNoticeInbox(
    private val adminKeys: AdminKeyTable,
    private val presenter: AdminNoticePresenter,
    private val nowMs: () -> Long,
    private val maxRecords: Int = MAX_DEDUP_RECORDS
) {
    /** Where a recorded notice has been seen (去重表). */
    private enum class Presence {
        /** 只從 Firestore 收過: this Gateway read it but nobody has put it on the mesh yet (#137). */
        BACKEND_ONLY,

        /** 已在 mesh 裡 (#137). */
        IN_MESH
    }

    private class Record(var presence: Presence, val keepUntilMs: Long)

    /** messageId → record, kept until expiresAt + [CLOCK_TOLERANCE_MS], at most [maxRecords]. */
    private val records = HashMap<String, Record>()

    init {
        require(maxRecords > 0) { "maxRecords must be positive" }
    }

    /**
     * A notice the Gateway's Firestore listener read from `admin_notices` (「Gateway：從 Firestore 注入
     * mesh」): steps 1, 2 and 4–6 of 收到 0x31 run on the `wire`; no other document field is
     * believed. A notice seen before, from either source, is a [AdminNoticeOutcome.Duplicate].
     */
    @Synchronized
    fun onBackendNotice(wire: ByteArray): AdminNoticeOutcome {
        val payload = when (val parsed = AdminNoticePayload.parse(wire)) {
            is AdminNoticePayload.Parsed.Invalid -> return AdminNoticeOutcome.Rejected(parsed.reason)
            is AdminNoticePayload.Parsed.Valid -> parsed.payload
        }
        val now = nowMs()
        untrustedReason(payload, now)?.let { return AdminNoticeOutcome.Rejected(it) }
        // Only now, with the signature verified, may the notice claim its messageId.
        if (!record(payload, Presence.BACKEND_ONLY, now)) return AdminNoticeOutcome.Duplicate
        present(payload)
        return AdminNoticeOutcome.Accepted(payload)
    }

    /** Steps 2 (keyId), 4, 5 and 6, in that order: the signature before anything else is believed. */
    private fun untrustedReason(payload: AdminNoticePayload, now: Long): AdminNoticeRejection? {
        val adminKey = adminKeys.publicKey(payload.keyId) ?: return AdminNoticeRejection.UNKNOWN_KEY_ID
        if (!payload.isSignedBy(adminKey)) return AdminNoticeRejection.BAD_SIGNATURE
        // Ordered so that no sum below can overflow: issuedAt is near now once the first check passes.
        if (payload.issuedAtMs > now + CLOCK_TOLERANCE_MS) return AdminNoticeRejection.ISSUED_IN_FUTURE
        if (payload.expiresAtMs <= payload.issuedAtMs || payload.expiresAtMs > payload.issuedAtMs + MAX_VALIDITY_MS) {
            return AdminNoticeRejection.BAD_VALIDITY
        }
        if (now > payload.expiresAtMs + CLOCK_TOLERANCE_MS) return AdminNoticeRejection.EXPIRED
        if (payload.replaces == payload.messageId) return AdminNoticeRejection.REPLACES_ITSELF
        return null
    }

    /** Step 8 for a new messageId; false when it is already recorded. */
    private fun record(payload: AdminNoticePayload, presence: Presence, now: Long): Boolean {
        records.values.removeAll { it.keepUntilMs < now }
        if (records.containsKey(payload.messageId)) return false
        records[payload.messageId] = Record(presence, payload.expiresAtMs + CLOCK_TOLERANCE_MS)
        if (records.size > maxRecords) {
            records.minByOrNull { it.value.keepUntilMs }?.let { records.remove(it.key) }
        }
        return true
    }

    /**
     * Step 11, as far as this ticket goes: a broadcast with text is shown. A pure revoke has nothing
     * to show (marking what it withdraws is #139), and a targeted notice waits for decryption (#141).
     */
    private fun present(payload: AdminNoticePayload) {
        val body = payload.body as? AdminNoticeBody.Broadcast ?: return
        if (body.content.isEmpty()) return
        presenter.present(
            ReceivedAdminNotice(
                messageId = payload.messageId,
                kind = payload.kind,
                level = payload.level,
                issuedAtMs = payload.issuedAtMs,
                expiresAtMs = payload.expiresAtMs,
                replaces = payload.replaces,
                content = body.content
            )
        )
    }

    companion object {
        /** 時鐘誤差容忍. */
        const val CLOCK_TOLERANCE_MS = 10 * 60_000L

        /** 有效期上限 (expiresAt − issuedAt). */
        const val MAX_VALIDITY_MS = 24 * 3_600_000L

        /** 去重表上限. */
        const val MAX_DEDUP_RECORDS = 1_000
    }
}
