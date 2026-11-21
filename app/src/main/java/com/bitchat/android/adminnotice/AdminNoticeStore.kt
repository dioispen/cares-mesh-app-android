package com.bitchat.android.adminnotice

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList

enum class AdminNoticeStatus {
    /** Shown as received. */
    ACTIVE,

    /** 已更正: a newer notice replaced it ([StoredAdminNotice.replacedBy]); its content is erased. */
    CORRECTED,

    /** 已撤回: a pure revoke withdrew it; its content is erased. Final: nothing changes it again. */
    WITHDRAWN
}

/** A received Admin Notice as this device keeps it for the notice list (#142). */
data class StoredAdminNotice(
    val messageId: String,
    val kind: AdminNoticeKind,
    val level: AdminNoticeLevel,
    val issuedAtMs: Long,
    val expiresAtMs: Long,
    val replaces: String?,
    val content: String,
    val status: AdminNoticeStatus,
    /** This device's clock when the notice was first stored. */
    val receivedAtMs: Long,
    /** The messageId of the notice that corrected this one ([AdminNoticeStatus.CORRECTED]). */
    val replacedBy: String? = null,
    /** This device's clock when the user first read it in the App; null while unread. */
    val readAtMs: Long? = null
) {
    val isRead: Boolean
        get() = readAtMs != null
}

/** 收件端的本機儲存: received notices by messageId, kept across App restarts. */
interface AdminNoticeStore {
    /** Saves [notice] unless its messageId is already stored; true when this was the first insert. */
    fun insertIfAbsent(notice: StoredAdminNotice): Boolean

    fun all(): List<StoredAdminNotice>

    /**
     * Marks [messageId] read now. Returns the notice as it is stored after this first reading;
     * null when it was already read or is not stored, so a caller acts once per notice.
     */
    fun markRead(messageId: String): StoredAdminNotice?

    /**
     * 已更正 (撤回與取代): [messageId] was replaced by [correctedBy]; its content is erased. Returns
     * the notice as it is stored now; null when it is not stored or not [AdminNoticeStatus.ACTIVE]
     * (a second correction does not move [StoredAdminNotice.replacedBy]), so a caller acts once.
     */
    fun markCorrected(messageId: String, correctedBy: String): StoredAdminNotice?

    /**
     * 已撤回 (撤回與取代): a pure revoke withdrew [messageId]; its content is erased. A corrected
     * notice can still be withdrawn. Null when it is not stored or already withdrawn.
     */
    fun markWithdrawn(messageId: String): StoredAdminNotice?

    /** [listener] hears of every notice stored and every change to one, until removed. */
    fun addChangeListener(listener: AdminNoticeChangeListener)

    fun removeChangeListener(listener: AdminNoticeChangeListener)
}

/**
 * Something in the store changed: a notice was stored, read, corrected or withdrawn.
 * Called on the writer's thread (the Inbox's, or the bridge's store thread) after the write is on
 * disk; it may read the store but should hand any slow work elsewhere.
 */
fun interface AdminNoticeChangeListener {
    fun onAdminNoticesChanged()
}

/**
 * [AdminNoticeStore] in EncryptedSharedPreferences, as the App keeps its identity keys: one entry
 * per messageId, holding the notice as JSON. Encrypted from the start because a targeted notice's
 * decrypted content (#141) must not sit on disk in the clear. Opening it touches the Android
 * Keystore, so [open] defers that to the first use, off the thread that builds it.
 */
class EncryptedAdminNoticeStore internal constructor(
    openPrefs: () -> SharedPreferences,
    private val nowMs: () -> Long
) : AdminNoticeStore {

    private val prefs by lazy(openPrefs)

    private val lock = Any()
    private val listeners = CopyOnWriteArrayList<AdminNoticeChangeListener>()

    override fun insertIfAbsent(notice: StoredAdminNotice): Boolean {
        val inserted = synchronized(lock) {
            prune()
            // commit, not apply: a notice notified now must still be on disk if the process dies next.
            !prefs.contains(notice.messageId) &&
                prefs.edit().putString(notice.messageId, encode(notice).toString()).commit()
        }
        if (inserted) notifyChanged()
        return inserted
    }

    /** Newest first, by issuedAt; a notice past its retention is gone. */
    override fun all(): List<StoredAdminNotice> = synchronized(lock) { prune() }.sortedWith(NEWEST_FIRST)

    override fun markRead(messageId: String): StoredAdminNotice? {
        val read = synchronized(lock) {
            val stored = prune().firstOrNull { it.messageId == messageId }
            stored?.takeUnless { it.isRead }
                ?.copy(readAtMs = nowMs())
                ?.takeIf { prefs.edit().putString(messageId, encode(it).toString()).commit() }
        }
        if (read != null) notifyChanged()
        return read
    }

    override fun markCorrected(messageId: String, correctedBy: String): StoredAdminNotice? =
        replace(messageId) { stored ->
            stored.takeIf { it.status == AdminNoticeStatus.ACTIVE }
                ?.copy(status = AdminNoticeStatus.CORRECTED, replacedBy = correctedBy, content = "")
        }

    override fun markWithdrawn(messageId: String): StoredAdminNotice? =
        replace(messageId) { stored ->
            stored.takeIf { it.status != AdminNoticeStatus.WITHDRAWN }
                ?.copy(status = AdminNoticeStatus.WITHDRAWN, content = "")
        }

    /**
     * Rewrites [messageId] as [change] makes it, unless that is null. The content goes for good:
     * the list never shows it again, the Administrator keeps the plaintext in
     * `admin_notice_records`, and what the Administrator took back should not linger on the phone,
     * least of all a targeted notice's decrypted text. [insertIfAbsent] never overwrites, so a
     * copy of the original received again, after an App restart too, does not bring it back.
     */
    private fun replace(messageId: String, change: (StoredAdminNotice) -> StoredAdminNotice?): StoredAdminNotice? {
        val changed = synchronized(lock) {
            prune().firstOrNull { it.messageId == messageId }
                ?.let(change)
                ?.takeIf { prefs.edit().putString(messageId, encode(it).toString()).commit() }
        }
        if (changed != null) notifyChanged()
        return changed
    }

    override fun addChangeListener(listener: AdminNoticeChangeListener) {
        listeners += listener
    }

    override fun removeChangeListener(listener: AdminNoticeChangeListener) {
        listeners -= listener
    }

    /** Outside [lock], so a listener may read the store. */
    private fun notifyChanged() {
        listeners.forEach { it.onAdminNoticesChanged() }
    }

    /**
     * Deletes the notices past 本機保留 (expiresAt + [RETENTION_MS]) and returns the rest. Entries
     * that cannot be read are left alone: they are not listed, and deleting them would lose a
     * notice whose format a later version may still understand.
     */
    private fun prune(): List<StoredAdminNotice> {
        val now = nowMs()
        val (gone, kept) = prefs.all
            .mapNotNull { (messageId, value) -> (value as? String)?.let { decode(messageId, it) } }
            .partition { now > it.expiresAtMs + RETENTION_MS }
        if (gone.isNotEmpty()) {
            val editor = prefs.edit()
            gone.forEach { editor.remove(it.messageId) }
            // apply: a notice the user can no longer see costs nothing if it outlives a crash.
            editor.apply()
        }
        return kept
    }

    companion object {
        private const val TAG = "AdminNoticeStore"
        internal const val PREFS_NAME = "cares_admin_notices"

        /** 本機保留: a notice stays listed, as 已過期, until this long after its expiresAt. */
        const val RETENTION_MS = 7 * 24 * 3_600_000L

        private val NEWEST_FIRST = compareByDescending<StoredAdminNotice> { it.issuedAtMs }
            .thenByDescending { it.receivedAtMs }
            .thenBy { it.messageId }

        fun open(context: Context, nowMs: () -> Long = System::currentTimeMillis): EncryptedAdminNoticeStore {
            val appContext = context.applicationContext
            return EncryptedAdminNoticeStore(nowMs = nowMs, openPrefs = {
                val masterKey = MasterKey.Builder(appContext, MasterKey.DEFAULT_MASTER_KEY_ALIAS)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                EncryptedSharedPreferences.create(
                    appContext,
                    PREFS_NAME,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
            })
        }

        private fun encode(notice: StoredAdminNotice) = JSONObject()
            .put("kind", notice.kind.name)
            .put("level", notice.level.name)
            .put("issuedAt", notice.issuedAtMs)
            .put("expiresAt", notice.expiresAtMs)
            .put("replaces", notice.replaces ?: JSONObject.NULL)
            .put("content", notice.content)
            .put("status", notice.status.name)
            .put("receivedAt", notice.receivedAtMs)
            .put("replacedBy", notice.replacedBy ?: JSONObject.NULL)
            .put("readAt", notice.readAtMs ?: JSONObject.NULL)

        private fun decode(messageId: String, json: String): StoredAdminNotice? = try {
            val o = JSONObject(json)
            StoredAdminNotice(
                messageId = messageId,
                kind = AdminNoticeKind.valueOf(o.getString("kind")),
                level = AdminNoticeLevel.valueOf(o.getString("level")),
                issuedAtMs = o.getLong("issuedAt"),
                expiresAtMs = o.getLong("expiresAt"),
                replaces = if (o.isNull("replaces")) null else o.getString("replaces"),
                content = o.getString("content"),
                status = AdminNoticeStatus.valueOf(o.getString("status")),
                receivedAtMs = o.getLong("receivedAt"),
                // Absent in notices stored before #142 (isNull is true for a missing key): unread.
                replacedBy = if (o.isNull("replacedBy")) null else o.getString("replacedBy"),
                readAtMs = if (o.isNull("readAt")) null else o.getLong("readAt")
            )
        } catch (e: JSONException) {
            Log.w(TAG, "Unreadable stored notice $messageId: ${e.message}")
            null
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Stored notice $messageId has an unknown value: ${e.message}")
            null
        }
    }
}
