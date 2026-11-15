package com.bitchat.android.adminnotice

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONException
import org.json.JSONObject

enum class AdminNoticeStatus {
    /** Shown as received. Corrected (已更正) and withdrawn (已撤回) arrive with #139. */
    ACTIVE
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
    val receivedAtMs: Long
)

/** 收件端的本機儲存: received notices by messageId, kept across App restarts. */
interface AdminNoticeStore {
    /** Saves [notice] unless its messageId is already stored; true when this was the first insert. */
    fun insertIfAbsent(notice: StoredAdminNotice): Boolean

    fun all(): List<StoredAdminNotice>
}

/**
 * [AdminNoticeStore] in EncryptedSharedPreferences, as the App keeps its identity keys: one entry
 * per messageId, holding the notice as JSON. Encrypted from the start because a targeted notice's
 * decrypted content (#141) must not sit on disk in the clear. Opening it touches the Android
 * Keystore, so [open] defers that to the first use, off the thread that builds it.
 */
class EncryptedAdminNoticeStore internal constructor(openPrefs: () -> SharedPreferences) : AdminNoticeStore {

    private val prefs by lazy(openPrefs)

    @Synchronized
    override fun insertIfAbsent(notice: StoredAdminNotice): Boolean {
        if (prefs.contains(notice.messageId)) return false
        // commit, not apply: a notice notified now must still be on disk if the process dies next.
        return prefs.edit().putString(notice.messageId, encode(notice).toString()).commit()
    }

    @Synchronized
    override fun all(): List<StoredAdminNotice> = prefs.all.mapNotNull { (messageId, value) ->
        (value as? String)?.let { decode(messageId, it) }
    }

    companion object {
        private const val TAG = "AdminNoticeStore"
        internal const val PREFS_NAME = "cares_admin_notices"

        fun open(context: Context): EncryptedAdminNoticeStore {
            val appContext = context.applicationContext
            return EncryptedAdminNoticeStore {
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
            }
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
                receivedAtMs = o.getLong("receivedAt")
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
