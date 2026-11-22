package com.bitchat.android.adminnotice

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.HKDFParameters
import java.security.GeneralSecurityException
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 收件者解密 of a 定向 body (docs/ADMIN_NOTICE_V1.md「定向 body」): only the devices the
 * Administrator encrypted to can open it, and a relay learns neither the content nor who it is for.
 */
internal object TargetedAdminNotice {
    private val RECIPIENT_INFO = "CARES-ADMIN-NOTICE-v1/recipient".toByteArray(Charsets.US_ASCII)
    private const val OKM_SIZE = 40
    private const val TAG_SIZE = 8
    private const val GCM_TAG_BITS = 128

    /**
     * The content of [payload] as this device's [key] opens it; null when this device is not one of
     * its recipients: no key, no entry's tag matches, or AES-GCM refuses the ciphertext.
     *
     * ```text
     * shared = agree(ephemeralPublicKey)
     * okm    = HKDF-SHA256(ikm = shared, salt = messageId,
     *                      info = "CARES-ADMIN-NOTICE-v1/recipient" || ephemeralPublicKey || R, L = 40)
     * tag    = okm[0:8], compared in constant time with every entry's
     * contentKey = wrappedKey XOR okm[8:40]; AES-256-GCM(contentKey, nonce, aad = header)
     * ```
     */
    fun open(payload: AdminNoticePayload, body: AdminNoticeBody.Targeted, key: AdminNoticeRecipientKey): String? {
        val ownPublicKey = key.publicKey() ?: return null
        val shared = key.agree(body.ephemeralPublicKey) ?: return null
        val header = payload.header
        val okm = hkdfSha256(
            ikm = shared,
            salt = header.copyOfRange(4, 4 + AdminNoticePayload.MESSAGE_ID_SIZE),
            info = RECIPIENT_INFO + body.ephemeralPublicKey + ownPublicKey
        )
        val tag = okm.copyOfRange(0, TAG_SIZE)
        // Every entry is compared, a match does not cut the loop short.
        var match: AdminNoticeBody.RecipientEntry? = null
        for (entry in body.recipients) {
            if (MessageDigest.isEqual(entry.tag, tag) && match == null) match = entry
        }
        val entry = match ?: return null
        val kek = okm.copyOfRange(TAG_SIZE, OKM_SIZE)
        val contentKey = ByteArray(kek.size) { i -> (entry.wrappedKey[i].toInt() xor kek[i].toInt()).toByte() }
        val plaintext = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(contentKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, body.nonce))
                updateAAD(header)
                doFinal(body.ciphertext)
            }
        } catch (e: GeneralSecurityException) {
            // A failed GCM check (AEADBadTagException) counts as not a recipient.
            return null
        }
        return String(plaintext, Charsets.UTF_8)
    }

    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
        val okm = ByteArray(OKM_SIZE)
        HKDFBytesGenerator(SHA256Digest()).apply { init(HKDFParameters(ikm, salt, info)) }.generateBytes(okm, 0, OKM_SIZE)
        return okm
    }
}
