package com.bitchat.android.net

import android.content.Context
import android.util.Log
import com.bitchat.android.R
import okhttp3.OkHttpClient
import okhttp3.Protocol
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Centralized OkHttp provider.
 */
object OkHttpProvider {
    private val httpClientRef = AtomicReference<OkHttpClient?>(null)
    private val wsClientRef = AtomicReference<OkHttpClient?>(null)

    fun reset() {
        httpClientRef.set(null)
        wsClientRef.set(null)
    }

    /**
     * Get HTTP client.
     * @param context Optional context to load the custom certificate from res/raw/cert.pem
     */
    fun httpClient(context: Context? = null): OkHttpClient {
        httpClientRef.get()?.let { return it }

        val builder = OkHttpClient.Builder()
            .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
            .callTimeout(30, TimeUnit.SECONDS)
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .hostnameVerifier { _, _ -> true }

        if (context != null) {
            try {
                // 嘗試從 R.raw.cert 載入自定義憑證
                val certInputStream = context.resources.openRawResource(R.raw.server)
                val cf = CertificateFactory.getInstance("X.509")
                val ca = cf.generateCertificate(certInputStream)
                certInputStream.close()

                val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
                    load(null, null)
                    setCertificateEntry("ca", ca)
                }

                val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {
                    init(keyStore)
                }

                val sslContext = SSLContext.getInstance("TLS").apply {
                    init(null, tmf.trustManagers, null)
                }
                builder.sslSocketFactory(sslContext.socketFactory, tmf.trustManagers[0] as X509TrustManager)
            } catch (e: Exception) {
                Log.e("OkHttpProvider", "Custom cert load failed, falling back to system default", e)
            }
        }

        val client = builder.build()
        httpClientRef.set(client)
        return client
    }

    fun webSocketClient(): OkHttpClient {
        wsClientRef.get()?.let { return it }
        val client = OkHttpClient.Builder()
            .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .build()
        wsClientRef.set(client)
        return client
    }
}
