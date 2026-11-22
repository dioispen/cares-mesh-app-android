package com.bitchat.android.identity

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom
import java.util.Base64

/**
 * This installation's Admin Notice recipient key (#140, docs/ADMIN_NOTICE_V1.md 收件者加密金鑰).
 *
 * One X25519 key pair per sign-in, bound to the uid that signed in. Flutter registers the public
 * key as `noticePublicKey` in `reporter_handles/{uid}/installations/{reporterHandle}`; an
 * Administrator encrypts targeted Admin Notices to it, and only this device can open them. The
 * private key never leaves this class: callers get the X25519 shared secret ([agree]), never the key.
 *
 * Deliberately not the Noise static key: that one survives a change of account, so the next person
 * signing in on this phone could still open the previous account's notices. This key is deleted on
 * sign-out ([clear]) and replaced whenever another account asks for it ([publicKeyFor]).
 *
 * Firebase-free, so the protocol layer can decrypt with it in the background. Every method reads
 * or writes encrypted storage; call them off the main thread. Thread-safe.
 */
class AdminNoticeRecipientKeyStore internal constructor(
    private val storage: SharedPreferences,
    /** 32 bytes for a new private key; tests pass fixed ones. */
    private val newPrivateKey: () -> ByteArray = ::randomPrivateKey
) {
    private val lock = Any()

    /**
     * The public key (32 bytes) bound to [uid], generating a pair when there is none.
     *
     * A key bound to another account is deleted first, then replaced: once this returns or throws,
     * this device can no longer open that account's notices. Throws [IllegalStateException] when
     * the storage cannot commit, so no public key is ever handed out without its private key kept.
     */
    fun publicKeyFor(uid: String): ByteArray = synchronized(lock) {
        val stored = load()
        if (stored != null && stored.uid == uid) return stored.publicKey()

        deleteKey()
        val privateKey = X25519PrivateKeyParameters(newPrivateKey(), 0)
        check(
            storage.edit()
                .putString(KEY_UID, uid)
                .putString(KEY_PRIVATE_KEY, Base64.getEncoder().encodeToString(privateKey.encoded))
                .commit()
        ) { "Could not save the Admin Notice recipient key" }
        privateKey.generatePublicKey().encoded
    }

    /** This device's current public key, or null when there is none (never signed in, or signed out). */
    fun publicKey(): ByteArray? = synchronized(lock) { load() }?.publicKey()

    /**
     * X25519 of this device's private key with a targeted Admin Notice's [ephemeralPublicKey]: the
     * `shared` its recipient entries are derived from.
     *
     * Null when there is no key, when [ephemeralPublicKey] is not 32 bytes, or when the result would
     * be all zeros (a small-order point; the sender aborts on that too). Null means "not for this
     * device", never an error.
     */
    fun agree(ephemeralPublicKey: ByteArray): ByteArray? {
        if (ephemeralPublicKey.size != X25519PublicKeyParameters.KEY_SIZE) return null
        val privateKey = synchronized(lock) { load() }?.privateKey ?: return null
        val agreement = X25519Agreement().apply { init(privateKey) }
        val shared = ByteArray(agreement.agreementSize)
        return try {
            agreement.calculateAgreement(X25519PublicKeyParameters(ephemeralPublicKey, 0), shared, 0)
            shared
        } catch (e: IllegalStateException) {
            // BouncyCastle refuses an all-zero result, which only a small-order point produces.
            null
        }
    }

    /** Deletes the key pair (sign-out, emergency clear). Throws [IllegalStateException] when it stays on disk. */
    fun clear() {
        synchronized(lock) { deleteKey() }
    }

    private fun deleteKey() {
        check(storage.edit().remove(KEY_UID).remove(KEY_PRIVATE_KEY).commit()) {
            "Could not delete the Admin Notice recipient key"
        }
    }

    /** The stored pair; null when there is none or it is unreadable (it is then replaced on the next sign-in). */
    private fun load(): StoredKey? {
        val uid = storage.getString(KEY_UID, null) ?: return null
        val encoded = storage.getString(KEY_PRIVATE_KEY, null) ?: return null
        val privateKey = try {
            Base64.getDecoder().decode(encoded)
        } catch (e: IllegalArgumentException) {
            return null
        }
        if (privateKey.size != X25519PrivateKeyParameters.KEY_SIZE) return null
        return StoredKey(uid, X25519PrivateKeyParameters(privateKey, 0))
    }

    private class StoredKey(val uid: String, val privateKey: X25519PrivateKeyParameters) {
        fun publicKey(): ByteArray = privateKey.generatePublicKey().encoded
    }

    companion object {
        /** Its own file: the identity store's panic wipe and this key's lifetime stay independent. */
        internal const val PREFS_NAME = "admin_notice_recipient_key"
        private const val KEY_UID = "uid"
        private const val KEY_PRIVATE_KEY = "private_key"

        @Volatile
        private var instance: AdminNoticeRecipientKeyStore? = null

        /**
         * The process-wide store over its own EncryptedSharedPreferences file, shared by the Flutter
         * bridge and the mesh service. The first call opens the keystore: not on the main thread.
         */
        fun getInstance(context: Context): AdminNoticeRecipientKeyStore =
            instance ?: synchronized(this) {
                instance ?: AdminNoticeRecipientKeyStore(openEncryptedStorage(context.applicationContext))
                    .also { instance = it }
            }

        private fun openEncryptedStorage(context: Context): SharedPreferences =
            EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                MasterKey.Builder(context, MasterKey.DEFAULT_MASTER_KEY_ALIAS)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build(),
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )

        private fun randomPrivateKey(): ByteArray =
            ByteArray(X25519PrivateKeyParameters.KEY_SIZE).also { SecureRandom().nextBytes(it) }
    }
}
