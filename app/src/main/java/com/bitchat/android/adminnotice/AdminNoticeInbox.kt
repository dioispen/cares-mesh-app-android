package com.bitchat.android.adminnotice

import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.util.AppConstants
import kotlin.random.Random

/**
 * AdminNoticeInbox（docs/ADMIN_NOTICE_V1.md「處理規則」）：every Admin Notice this device receives
 * goes through here, and is trusted only by an Administrator's signature (ADR-0011), never by the
 * Gateway or backend copy it came through.
 *
 * Inputs: [onBackendNotice] (the Gateway's Firestore listener, #136) and [onMeshPacket] (the mesh's
 * 0x31 packets, #137). Outputs go only to injected ports — [presenter], and the injector and sync
 * set the running mesh service attaches ([attachInjector], [attachSyncSet], #138), with receipts
 * (#143) behind the presenter's own port — and so do the clock, the injection delay's scheduler and
 * random source, and this device's [recipientKey] for targeted notices (#141), so every rule runs in
 * a plain JVM test. Firebase-free.
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
    private val maxRecords: Int = MAX_DEDUP_RECORDS,
    /** Opens targeted notices; a device without one presents only broadcasts. */
    private val recipientKey: AdminNoticeRecipientKey = AdminNoticeRecipientKey.NONE
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

    /**
     * 撤回紀錄: replaced messageId → kept until, the replacing notice's expiresAt +
     * [CLOCK_TOLERANCE_MS], at most [maxRecords]. Memory only, like [records].
     */
    private val revoked = HashMap<String, Long>()

    /** messageId → cancels its scheduled injection (待注入). Only BACKEND_ONLY notices have one. */
    private val pendingInjections = HashMap<String, () -> Unit>()

    /** The running mesh service, through which this Gateway injects; null while none runs. */
    private var injector: AdminNoticeInjector? = null

    /** A notice in the mesh as its sync set is offered it: the normalized outer packet and expiresAt. */
    private class InMeshNotice(val packet: BitchatPacket, val expiresAtMs: Long)

    /**
     * messageId → every notice in the mesh that has not expired, at most
     * [AppConstants.Sync.ADMIN_NOTICE_CAPACITY] (the one expiring first goes, as in the sync set).
     * This Inbox outlives the mesh service, whose sync set starts empty each time, and a notice
     * already in the mesh is not injected again: [attachSyncSet] hands these to the new one.
     */
    private val inMeshNotices = HashMap<String, InMeshNotice>()

    /** The running mesh service's gossip sync; null while none runs. */
    private var syncSet: AdminNoticeSyncSet? = null

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
        if (isRevoked(payload.messageId, now)) return AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED)
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
        replaceEarlier(payload)
        present(payload, AdminNoticeSource.BACKEND)
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
        if (isRevoked(payload.messageId, now)) return AdminNoticeOutcome.Rejected(AdminNoticeRejection.REVOKED)
        // Step 8, only now that the signature is verified: a forged copy never claims a messageId.
        when (presenceOf(payload.messageId, now)) {
            Presence.IN_MESH -> return AdminNoticeOutcome.Duplicate
            // This Gateway read it from the backend and was waiting to inject it: someone else did.
            // Already presented then; relayed now like any first mesh copy.
            Presence.BACKEND_ONLY -> markInMesh(payload)
            null -> {
                replaceEarlier(payload)
                markInMesh(payload)
                present(payload, AdminNoticeSource.MESH)
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
     * The mesh service, once it runs, offers notices to late arrivals through [syncSet]: it is
     * handed at once every unexpired notice already in the mesh, then each one entering it. A later
     * call replaces the one attached before.
     */
    @Synchronized
    fun attachSyncSet(syncSet: AdminNoticeSyncSet) {
        this.syncSet = syncSet
        forgetExpiredInMesh(nowMs())
        inMeshNotices.values.forEach { syncSet.add(it.packet, it.expiresAtMs) }
    }

    /** The mesh service stopped. Ignored unless [syncSet] is the one attached, as for the injector. */
    @Synchronized
    fun detachSyncSet(syncSet: AdminNoticeSyncSet) {
        if (this.syncSet === syncSet) this.syncSet = null
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

    /** Step 7, after forgetting the revocations that have expired. */
    private fun isRevoked(messageId: String, now: Long): Boolean {
        revoked.values.removeAll { keepUntilMs -> keepUntilMs < now }
        return messageId in revoked
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
     * inject it any more, and (step 10) it joins the sync set, so injected and heard notices join it
     * alike and only ever after the signature was verified.
     */
    private fun markInMesh(payload: AdminNoticePayload) {
        pendingInjections.remove(payload.messageId)?.invoke()
        remember(payload, Presence.IN_MESH)
        offerToSync(payload)
    }

    /**
     * Step 10: [AdminNoticePacket.outer] of [payload] goes to the sync set until its expiresAt. One
     * accepted within the clock tolerance after its expiresAt has nothing left to offer.
     */
    private fun offerToSync(payload: AdminNoticePayload) {
        val now = nowMs()
        forgetExpiredInMesh(now)
        if (payload.expiresAtMs <= now) return
        val notice = InMeshNotice(AdminNoticePacket.outer(payload), payload.expiresAtMs)
        inMeshNotices[payload.messageId] = notice
        if (inMeshNotices.size > AppConstants.Sync.ADMIN_NOTICE_CAPACITY) {
            val first = inMeshNotices.minByOrNull { it.value.expiresAtMs } ?: return
            inMeshNotices.remove(first.key)
            // The sync set drops the same one when full: no need to offer it this one.
            if (first.key == payload.messageId) return
        }
        syncSet?.add(notice.packet, notice.expiresAtMs)
    }

    private fun forgetExpiredInMesh(now: Long) {
        inMeshNotices.values.removeAll { it.expiresAtMs <= now }
    }

    /**
     * Step 9 (撤回與取代), only for a verified notice seen for the first time: the notice it replaces
     * goes into the revocation record, is no longer offered to late arrivals nor injected by this
     * Gateway, and is marked here as corrected, or withdrawn by a pure revoke.
     */
    private fun replaceEarlier(payload: AdminNoticePayload) {
        val replaced = payload.replaces ?: return
        revoke(replaced, until = payload.expiresAtMs + CLOCK_TOLERANCE_MS)
        pendingInjections.remove(replaced)?.invoke()
        inMeshNotices.remove(replaced)
        syncSet?.remove(replaced)
        if (payload.isPureRevoke) {
            presenter.withdraw(replaced)
        } else {
            presenter.correct(replaced, correctedBy = payload.messageId)
        }
    }

    /**
     * Records [messageId] in the revocation record until [until], the replacing notice's expiresAt
     * plus the clock tolerance: a device accepts the original that long after its own expiresAt,
     * which the replacing notice's is never earlier than. Past [maxRecords] the revocation expiring
     * first is forgotten, as in the dedup table.
     */
    private fun revoke(messageId: String, until: Long) {
        revoked[messageId] = maxOf(until, revoked[messageId] ?: until)
        if (revoked.size > maxRecords) {
            revoked.minByOrNull { it.value }?.let { revoked.remove(it.key) }
        }
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
        val now = nowMs()
        // Replaced meanwhile: its cancellation may have come too late to stop this run.
        if (isRevoked(payload.messageId, now)) return
        if (presenceOf(payload.messageId, now) != Presence.BACKEND_ONLY) return
        val mesh = injector ?: return
        if (!mesh.inject(AdminNoticePacket.outer(payload))) return
        markInMesh(payload)
    }

    /**
     * Step 11 (本機呈現), once per notice, for the first copy that arrived ([source]): a broadcast with
     * text is shown, a targeted notice only when this device opens it (#141). A pure revoke has
     * nothing to show: what it withdraws was marked in step 9 ([replaceEarlier]).
     *
     * Runs after the notice is recorded, and its outcome is already decided: whether this device
     * can read a notice never changes whether it is relayed or injected.
     */
    private fun present(payload: AdminNoticePayload, source: AdminNoticeSource) {
        val content = when (val body = payload.body) {
            is AdminNoticeBody.Broadcast -> body.content
            is AdminNoticeBody.Targeted -> openForThisDevice(payload, body) ?: return
        }
        if (content.isEmpty()) return
        presenter.present(
            ReceivedAdminNotice(
                messageId = payload.messageId,
                kind = payload.kind,
                level = payload.level,
                issuedAtMs = payload.issuedAtMs,
                expiresAtMs = payload.expiresAtMs,
                replaces = payload.replaces,
                content = content,
                source = source
            )
        )
    }

    /**
     * The content of a targeted notice for this device; null when it is not a recipient. A key that
     * cannot be read counts as none: an exception here would reach the mesh as "do not relay", for
     * a notice already recorded as in the mesh, so no later copy would be relayed either.
     */
    private fun openForThisDevice(payload: AdminNoticePayload, body: AdminNoticeBody.Targeted): String? = try {
        TargetedAdminNotice.open(payload, body, recipientKey)
    } catch (e: Exception) {
        // Exception, not RuntimeException: the Android Keystore's are checked, and Kotlin lets a port throw them.
        null
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
