package com.bitchat.android.adminnotice

import com.bitchat.android.protocol.BitchatPacket
import kotlin.random.Random

/**
 * AdminNoticeInbox（docs/ADMIN_NOTICE_V1.md「處理規則」）：every Admin Notice this device receives
 * goes through here, and is trusted only by an Administrator's signature (ADR-0011), never by the
 * Gateway or backend copy it came through.
 *
 * Inputs: [onBackendNotice] (the Gateway's Firestore listener, #136) and [onMeshPacket] (the mesh's
 * 0x31 packets, #137). Outputs go only to injected ports — [presenter], and the injector the
 * running mesh service attaches ([attachInjector]); the sync set (#138), the recipient key (#141)
 * and receipts (#143) come as further ports — and the clock and the injection delay's scheduler and
 * random source are injected too, so every rule runs in a plain JVM test. Firebase-free.
 *
 * Calls are serialised on this object's lock and return a decision at once, so the mesh can decide
 * whether to relay a packet while handling it. The dedup table is memory only: after an App restart
 * a notice is processed as new, and [presenter]'s store keeps it from notifying twice.
 */
class AdminNoticeInbox(
    private val adminKeys: AdminKeyTable,
    private val presenter: AdminNoticePresenter,
    private val nowMs: () -> Long,
    /** Runs a Gateway's injection once its delay has passed. */
    private val injectionScheduler: AdminNoticeScheduler,
    /** Gateway 注入延遲: uniform over 0–15 s, so that Gateways reading the same notice rarely all inject. */
    private val injectionDelayMs: () -> Long = { Random.nextLong(MAX_INJECTION_DELAY_MS + 1) },
    private val maxRecords: Int = MAX_DEDUP_RECORDS
) {
    /** Where a recorded notice has been seen (去重表). */
    private enum class Presence {
        /** 只從 Firestore 收過: this Gateway read it but nobody has put it on the mesh yet. */
        BACKEND_ONLY,

        /** 已在 mesh 裡: heard over the mesh, or injected by this Gateway. */
        IN_MESH
    }

    private class Record(val presence: Presence, val keepUntilMs: Long)

    /** messageId → record, kept until expiresAt + [CLOCK_TOLERANCE_MS], at most [maxRecords]. */
    private val records = HashMap<String, Record>()

    /** messageId → cancels its scheduled injection (待注入). Only BACKEND_ONLY notices have one. */
    private val pendingInjections = HashMap<String, () -> Unit>()

    /** The running mesh service, through which this Gateway injects; null while none runs. */
    private var injector: AdminNoticeInjector? = null

    init {
        require(maxRecords > 0) { "maxRecords must be positive" }
    }

    /**
     * A notice the Gateway's Firestore listener read from `admin_notices` (「Gateway：從 Firestore 注入
     * mesh」): steps 1, 2 and 4–6 of 收到 0x31 run on the `wire`; no other document field is
     * believed. A new one is presented and its injection scheduled; a notice seen before, from
     * either source, is a [AdminNoticeOutcome.Duplicate].
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
        when (presenceOf(payload.messageId, now)) {
            // Somebody, maybe this Gateway, has already put it on the mesh.
            Presence.IN_MESH -> return AdminNoticeOutcome.Duplicate
            // Read again, e.g. after the listener re-attached: presented the first time, and its
            // injection still pending unless the mesh service stopped or was missing meanwhile.
            Presence.BACKEND_ONLY -> {
                if (payload.messageId !in pendingInjections) scheduleInjection(payload)
                return AdminNoticeOutcome.Duplicate
            }
            null -> Unit
        }
        remember(payload, Presence.BACKEND_ONLY)
        present(payload)
        scheduleInjection(payload)
        return AdminNoticeOutcome.Accepted(payload)
    }

    /**
     * A 0x31 packet heard over the mesh (「收到 0x31」), Gateway or not. The returned outcome's
     * [AdminNoticeOutcome.relay] is the packet's `validPacket`.
     */
    @Synchronized
    fun onMeshPacket(packet: BitchatPacket): AdminNoticeOutcome {
        val payload = when (val parsed = AdminNoticePayload.parse(packet.payload)) {
            is AdminNoticePayload.Parsed.Invalid -> return AdminNoticeOutcome.Rejected(parsed.reason)
            is AdminNoticePayload.Parsed.Valid -> parsed.payload
        }
        val now = nowMs()
        untrustedReason(payload, now, outer = packet)?.let { return AdminNoticeOutcome.Rejected(it) }
        // Step 8, only now that the signature is verified: a forged copy never claims a messageId.
        when (presenceOf(payload.messageId, now)) {
            Presence.IN_MESH -> return AdminNoticeOutcome.Duplicate
            // This Gateway read it from the backend and was waiting to inject it: someone else did.
            // Already presented then; relayed now like any first mesh copy.
            Presence.BACKEND_ONLY -> markInMesh(payload)
            null -> {
                markInMesh(payload)
                present(payload)
            }
        }
        return AdminNoticeOutcome.Accepted(payload)
    }

    /**
     * The mesh service, once it runs, injects this Gateway's notices from now on. A later call
     * replaces the one attached before.
     */
    @Synchronized
    fun attachInjector(injector: AdminNoticeInjector) {
        this.injector = injector
    }

    /**
     * The mesh service stopped: every pending injection is cancelled (「mesh 服務停止時取消所有待
     * 注入」). Ignored unless [injector] is the one attached, so an instance replaced by a newer one
     * cannot cancel its successor's injections when it stops late.
     */
    @Synchronized
    fun detachInjector(injector: AdminNoticeInjector) {
        if (this.injector !== injector) return
        this.injector = null
        pendingInjections.values.forEach { cancel -> cancel() }
        pendingInjections.clear()
    }

    /**
     * Steps 2 (keyId), 3 (only for a mesh copy, its [outer] packet), 4, 5 and 6, in that order: the
     * signature before anything else is believed.
     */
    private fun untrustedReason(
        payload: AdminNoticePayload,
        now: Long,
        outer: BitchatPacket? = null
    ): AdminNoticeRejection? {
        val adminKey = adminKeys.publicKey(payload.keyId) ?: return AdminNoticeRejection.UNKNOWN_KEY_ID
        if (outer != null && !AdminNoticePacket.matches(outer, payload)) return AdminNoticeRejection.OUTER_MISMATCH
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

    /** Step 8's lookup, after forgetting what has expired: null when [messageId] is not recorded. */
    private fun presenceOf(messageId: String, now: Long): Presence? {
        records.values.removeAll { it.keepUntilMs < now }
        return records[messageId]?.presence
    }

    /** Records (or moves) [payload]'s messageId; past [maxRecords] the one expiring first is forgotten. */
    private fun remember(payload: AdminNoticePayload, presence: Presence) {
        records[payload.messageId] = Record(presence, payload.expiresAtMs + CLOCK_TOLERANCE_MS)
        if (records.size > maxRecords) {
            records.minByOrNull { it.value.keepUntilMs }?.let { records.remove(it.key) }
        }
    }

    /**
     * [payload] is in the mesh now, heard (step 8) or injected by this Gateway: nobody needs to
     * inject it any more. Step 10 belongs here too: #138 adds [AdminNoticePacket.outer] of [payload]
     * to the gossip sync set until its expiresAt, so injected and heard notices join it alike.
     */
    private fun markInMesh(payload: AdminNoticePayload) {
        pendingInjections.remove(payload.messageId)?.invoke()
        remember(payload, Presence.IN_MESH)
    }

    /** Gateway: inject [payload] after a random delay unless the mesh brings it first. */
    private fun scheduleInjection(payload: AdminNoticePayload) {
        pendingInjections[payload.messageId] =
            injectionScheduler.schedule(injectionDelayMs()) { injectWhenDue(payload) }
    }

    /**
     * The delay has passed: inject the normalized packet unless the notice reached the mesh, or was
     * forgotten, meanwhile. Without a mesh service to hand it to, the injection is dropped.
     */
    @Synchronized
    private fun injectWhenDue(payload: AdminNoticePayload) {
        pendingInjections.remove(payload.messageId)
        if (presenceOf(payload.messageId, nowMs()) != Presence.BACKEND_ONLY) return
        val mesh = injector ?: return
        if (!mesh.inject(AdminNoticePacket.outer(payload))) return
        markInMesh(payload)
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

        /** Gateway 注入延遲的上限: the delay is uniform over 0..this, inclusive. */
        const val MAX_INJECTION_DELAY_MS = 15_000L
    }
}
