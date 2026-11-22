package com.bitchat.android.adminnotice

import android.util.Log
import com.bitchat.android.identity.AdminNoticeRecipientKeyStore

/**
 * The Inbox's [AdminNoticeRecipientKey] on a phone: this process's [AdminNoticeRecipientKeyStore],
 * the same instance the Flutter bridge registers (`adminNotice_getPublicKey`) and clears
 * (`adminNotice_clearKey`), so a sign-out stops the next targeted notice from being opened.
 *
 * [store] is resolved on every call, never at construction: opening it touches the Android Keystore,
 * which must not happen on the main thread that builds the Inbox. A store that cannot be opened or
 * read is no key (logged), and the next notice tries again.
 */
class StoredAdminNoticeRecipientKey(
    private val store: () -> AdminNoticeRecipientKeyStore
) : AdminNoticeRecipientKey {

    override fun publicKey(): ByteArray? = read { it.publicKey() }

    override fun agree(ephemeralPublicKey: ByteArray): ByteArray? = read { it.agree(ephemeralPublicKey) }

    private inline fun read(use: (AdminNoticeRecipientKeyStore) -> ByteArray?): ByteArray? = try {
        use(store())
    } catch (e: Exception) {
        Log.w(TAG, "Admin Notice recipient key unavailable; targeted notices are not opened: ${e.message}")
        null
    }

    private companion object {
        const val TAG = "AdminNoticeRecipientKey"
    }
}
