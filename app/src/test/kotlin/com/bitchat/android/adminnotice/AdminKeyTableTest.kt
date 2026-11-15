package com.bitchat.android.adminnotice

import android.os.Build
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * The App trusts an Admin Notice only by the keys built into it (ADR-0011). The built-in table
 * must be exactly `tools/admin-notice/admin_public_keys.json`, and must never contain the
 * test-vector key: its private seed is published in docs/ADMIN_NOTICE_V1.md.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class AdminKeyTableTest {

    @Test
    fun `the production table is exactly the registered public keys`() {
        val registered = JSONObject(registeredKeysFile().readText())
        val expected = registered.keys().asSequence().associate { name ->
            Integer.decode(name) to hex(registered.getString(name))
        }

        assertEquals(expected.keys, AdminKeyTable.PRODUCTION.keyIds)
        expected.forEach { (keyId, publicKey) ->
            assertArrayEquals("keyId $keyId", publicKey, AdminKeyTable.PRODUCTION.publicKey(keyId))
        }
    }

    @Test
    fun `the production table does not trust the test-vector key`() {
        val testKey = hex(TestAdminNotices.TEST_ADMIN_PUBLIC_KEY_HEX)

        assertFalse(AdminKeyTable.PRODUCTION.keyIds.any { AdminKeyTable.PRODUCTION.publicKey(it)!!.contentEquals(testKey) })
    }

    @Test
    fun `an unknown keyId has no key`() {
        assertNull(AdminKeyTable.PRODUCTION.publicKey(0x02))
        assertNull(AdminKeyTable.PRODUCTION.publicKey(0x00))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `keyId 0x00 is reserved`() {
        AdminKeyTable(mapOf(0x00 to ByteArray(32)))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a public key must be 32 bytes`() {
        AdminKeyTable(mapOf(0x01 to ByteArray(31)))
    }

    /** Unit tests run in the module directory; the registry sits at the repo root. */
    private fun registeredKeysFile(): File =
        listOf(File("../tools/admin-notice/admin_public_keys.json"), File("tools/admin-notice/admin_public_keys.json"))
            .first { it.isFile }
}
