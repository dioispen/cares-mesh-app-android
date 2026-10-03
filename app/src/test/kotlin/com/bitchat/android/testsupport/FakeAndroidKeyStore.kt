package com.bitchat.android.testsupport

import java.io.InputStream
import java.io.OutputStream
import java.security.Key
import java.security.KeyStoreSpi
import java.security.Provider
import java.security.Security
import java.security.cert.Certificate
import java.util.Collections
import java.util.Date
import java.util.Enumeration
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.KeyGenerator

/**
 * A software stand-in for Android's "AndroidKeyStore", for Robolectric tests only.
 *
 * Robolectric has no AndroidKeyStore, so anything that opens `EncryptedSharedPreferences` (the
 * mesh's `EncryptionService`, `SecureIdentityStateManager`) cannot be constructed. [install]
 * registers an in-memory "AndroidKeyStore" `KeyStore` already holding androidx.security's default
 * master key, an AES-256 key from the JVM's own generator. `MasterKey.Builder` then finds the key
 * instead of generating one (a JCE `KeyGenerator` from a test class loader cannot be authenticated),
 * and Tink wraps its keyset with it through the JVM's AES-GCM. [uninstall] afterwards.
 */
internal object FakeAndroidKeyStore {
    private const val NAME = "AndroidKeyStore"

    /** `androidx.security.crypto.MasterKey.DEFAULT_MASTER_KEY_ALIAS`. */
    private const val DEFAULT_MASTER_KEY_ALIAS = "_androidx_security_master_key_"

    private val keys = ConcurrentHashMap<String, Key>()

    fun install() {
        // Robolectric gives every test class its own class loader; a provider left behind by
        // another class would hand out SPIs from a foreign loader.
        uninstall()
        keys[DEFAULT_MASTER_KEY_ALIAS] = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        Security.addProvider(FakeProvider())
    }

    fun uninstall() {
        Security.removeProvider(NAME)
        keys.clear()
    }

    @Suppress("DEPRECATION") // Provider(String, String, String) is not in android.jar
    private class FakeProvider : Provider(NAME, 1.0, "in-memory AndroidKeyStore for tests") {
        init {
            put("KeyStore.$NAME", FakeKeyStoreSpi::class.java.name)
        }
    }

    class FakeKeyStoreSpi : KeyStoreSpi() {
        override fun engineGetKey(alias: String, password: CharArray?): Key? = keys[alias]
        override fun engineGetCertificateChain(alias: String): Array<Certificate>? = null
        override fun engineGetCertificate(alias: String): Certificate? = null
        override fun engineGetCreationDate(alias: String): Date? = if (keys.containsKey(alias)) Date(0) else null
        override fun engineSetKeyEntry(alias: String, key: Key, password: CharArray?, chain: Array<out Certificate>?) {
            keys[alias] = key
        }
        override fun engineSetKeyEntry(alias: String, key: ByteArray, chain: Array<out Certificate>?) =
            throw UnsupportedOperationException()
        override fun engineSetCertificateEntry(alias: String, cert: Certificate) =
            throw UnsupportedOperationException()
        override fun engineDeleteEntry(alias: String) {
            keys.remove(alias)
        }
        override fun engineAliases(): Enumeration<String> = Collections.enumeration(keys.keys.toList())
        override fun engineContainsAlias(alias: String): Boolean = keys.containsKey(alias)
        override fun engineSize(): Int = keys.size
        override fun engineIsKeyEntry(alias: String): Boolean = keys.containsKey(alias)
        override fun engineIsCertificateEntry(alias: String): Boolean = false
        override fun engineGetCertificateAlias(cert: Certificate): String? = null
        override fun engineStore(stream: OutputStream?, password: CharArray?) = Unit
        override fun engineLoad(stream: InputStream?, password: CharArray?) = Unit
    }
}
