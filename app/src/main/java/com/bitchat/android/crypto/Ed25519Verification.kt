package com.bitchat.android.crypto

import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer

/**
 * The App's Ed25519 signature check (BouncyCastle), shared by [EncryptionService] and the Admin
 * Notice Inbox, which must verify the Administrators' signature without a mesh identity.
 */
object Ed25519Verification {
    /** False for a wrong signature and for malformed input alike; never throws. */
    fun verify(signature: ByteArray, data: ByteArray, publicKey: ByteArray): Boolean = try {
        val verifier = Ed25519Signer()
        verifier.init(false, Ed25519PublicKeyParameters(publicKey, 0))
        verifier.update(data, 0, data.size)
        verifier.verifySignature(signature)
    } catch (e: Exception) {
        false
    }
}
