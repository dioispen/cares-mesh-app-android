package com.bitchat.android.sync

import android.content.Context
import android.util.Base64
import android.util.Log
import com.bitchat.android.identity.SecureIdentityStateManager

/**
 * Keeps [OwnHealthReportKeeper]'s slot in the identity's encrypted preferences
 * ([SecureIdentityStateManager]).
 *
 * The packet holds only the Broadcast Tier the Reporter already broadcast (Status, SOS mark,
 * approximate location), but on disk it is a lasting record of where they were, so it is
 * encrypted at rest like the keys it is signed with. Sharing their file also bounds its lifetime
 * by that identity's: a panic wipe (`clearIdentityData`) erases it together with the keys.
 */
class EncryptedOwnHealthReportStore internal constructor(
    openIdentityStore: () -> SecureIdentityStateManager
) : OwnHealthReportStore {

    constructor(context: Context) : this({ SecureIdentityStateManager(context.applicationContext) })

    // Opening the encrypted preferences goes through the Android Keystore: done on first use,
    // which the keeper makes on an I/O thread
    private val identityStore by lazy(openIdentityStore)

    override fun read(): ByteArray? =
        identityStore.getSecureValue(KEY)?.let { Base64.decode(it, Base64.NO_WRAP) }

    override fun write(encoded: ByteArray) {
        identityStore.storeSecureValue(KEY, Base64.encodeToString(encoded, Base64.NO_WRAP))
    }

    override fun clear() {
        if (!identityStore.clearSecureValuesSynchronously(KEY)) {
            Log.e(TAG, "Own health report erase could not be committed")
        }
    }

    private companion object {
        const val TAG = "OwnHealthReportStore"
        const val KEY = "own_health_report_v1"
    }
}
