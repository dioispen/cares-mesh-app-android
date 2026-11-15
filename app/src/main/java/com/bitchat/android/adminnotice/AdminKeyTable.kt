package com.bitchat.android.adminnotice

import com.bitchat.android.util.dataFromHexString

/**
 * The Administrators' Ed25519 public keys this App trusts, by keyId (docs/ADMIN_NOTICE_V1.md「金鑰」).
 * An Admin Notice is trusted only if one of these keys signed it (ADR-0011); a keyId missing here is
 * an unknown key, whatever the notice says.
 */
class AdminKeyTable(keys: Map<Int, ByteArray>) {

    private val keys: Map<Int, ByteArray> = keys.mapValues { (keyId, publicKey) ->
        require(keyId in 0x01..0xFF) { "keyId 0x%02x is not a valid keyId; 0x00 is reserved".format(keyId) }
        require(publicKey.size == PUBLIC_KEY_SIZE) { "keyId 0x%02x: an Ed25519 public key is 32 bytes".format(keyId) }
        publicKey.copyOf()
    }

    val keyIds: Set<Int> get() = keys.keys

    /** A copy of the key registered under [keyId], or null when this App does not know it. */
    fun publicKey(keyId: Int): ByteArray? = keys[keyId]?.copyOf()

    companion object {
        private const val PUBLIC_KEY_SIZE = 32

        /**
         * The built-in table, copied from `tools/admin-notice/admin_public_keys.json` (a test keeps
         * them equal). Changing a key means shipping a new App version: see 換 key in the spec.
         * Never add the test-vector key: its private seed is public.
         */
        val PRODUCTION = AdminKeyTable(
            mapOf(
                0x01 to "daf8fb8beae09327662cb4ad1c3505f3c45fba6af9c13d7c61e79827f9b312a4".dataFromHexString()!!
            )
        )
    }
}
