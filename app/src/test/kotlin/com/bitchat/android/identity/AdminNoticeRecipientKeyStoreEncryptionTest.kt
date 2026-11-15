package com.bitchat.android.identity

import android.content.Context
import android.os.Build
import com.bitchat.android.testsupport.FakeAndroidKeyStore
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.Base64

/** The production store (#140): one per process, over EncryptedSharedPreferences. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.P], manifest = Config.NONE)
class AdminNoticeRecipientKeyStoreEncryptionTest {

    private val context: Context = RuntimeEnvironment.getApplication()

    @Before
    fun setUp() {
        FakeAndroidKeyStore.install()
    }

    @After
    fun tearDown() {
        FakeAndroidKeyStore.uninstall()
    }

    @Test
    fun `the bridge and the mesh service share one store, and its file keeps nothing readable`() {
        val store = AdminNoticeRecipientKeyStore.getInstance(context)
        assertSame(store, AdminNoticeRecipientKeyStore.getInstance(context))

        val publicKey = store.publicKeyFor("uid-alice")
        assertNotNull(store.agree(ByteArray(32) { 9 }))
        assertArrayEquals(publicKey, store.publicKey())

        val onDisk = context.getSharedPreferences(AdminNoticeRecipientKeyStore.PREFS_NAME, Context.MODE_PRIVATE).all
        val plaintext = onDisk.keys + onDisk.values.map { it.toString() }
        val publicKeyText = Base64.getEncoder().encodeToString(publicKey)
        assertFalse(plaintext.toString(), plaintext.any { "uid-alice" in it || "uid" == it || publicKeyText in it })

        store.clear()
    }
}
