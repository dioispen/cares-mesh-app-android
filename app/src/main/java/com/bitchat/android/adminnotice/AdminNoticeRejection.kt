package com.bitchat.android.adminnotice

/** Why the Inbox refused a notice: it is neither presented nor (#137) relayed. */
enum class AdminNoticeRejection {
    /** Step 1: too short, a body that does not fit its kind, content over 300 bytes, a zero messageId. */
    MALFORMED,

    /** Step 2: an unknown version, kind or level. */
    UNSUPPORTED,

    /** Step 2: the keyId is not in this App's [AdminKeyTable]. */
    UNKNOWN_KEY_ID,

    /**
     * Step 3, mesh copies only: the packet's senderID is not the notice's messageId, or its
     * timestamp is not the notice's issuedAt (「外層封包」).
     */
    OUTER_MISMATCH,

    /** Step 4: no Administrator signed this. */
    BAD_SIGNATURE,

    /** Step 5: issuedAt is more than the clock tolerance ahead of this device. */
    ISSUED_IN_FUTURE,

    /** Step 5: expiresAt plus the clock tolerance has passed. */
    EXPIRED,

    /** Step 5: expiresAt is not after issuedAt, or more than 24 hours after it. */
    BAD_VALIDITY,

    /** Step 6: the notice names itself in replaces. */
    REPLACES_ITSELF
}
