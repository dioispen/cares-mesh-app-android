package com.bitchat.android.mesh

import com.bitchat.android.protocol.HealthReportPayload
import com.bitchat.android.util.AppConstants

/**
 * Tells a new statement from a repeat of one already handled, by Reporter Handle and `reportTime`.
 *
 * Packet IDs cannot: a Reporter's device re-sends a standing Health Report newly signed and
 * timestamped, with the payload unchanged (ADR-0010), and SecurityManager forgets a packet ID
 * after a few minutes, so a synced copy can come round again too. Only a report newer than every
 * earlier one from that Reporter is new; an older one that arrives late counts as a repeat.
 */
internal class HealthReportRepeatFilter(
    private val capacity: Int = AppConstants.Sync.MAX_HEALTH_REPORT_SIGNING_KEYS
) {
    // Reporter Handle -> newest reportTime seen, least recently updated first
    private val newest = LinkedHashMap<String, Long>()

    @Synchronized
    fun isNew(report: HealthReportPayload): Boolean {
        val seen = newest[report.reporterHandle]
        if (seen != null && seen >= report.reportTimeMillis) return false
        newest.remove(report.reporterHandle)
        newest[report.reporterHandle] = report.reportTimeMillis
        while (newest.size > capacity) {
            val eldest = newest.keys.iterator()
            eldest.next()
            eldest.remove()
        }
        return true
    }
}
