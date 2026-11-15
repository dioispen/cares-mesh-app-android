package com.bitchat.android.flutter

import com.bitchat.android.identity.AdminNoticeRecipientKeyStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The Admin Notice half of the Flutter bridge (#140, docs/ADMIN_NOTICE_V1.md 收件者加密金鑰).
 *
 * For now only the recipient key: Flutter registers this device's public key with the Reporter
 * Handle registration and asks for it to be deleted on sign-out and emergency clear.
 * - [METHOD_GET_PUBLIC_KEY] `{uid: String}` → the 32-byte public key bound to `uid` (a Dart
 *   `Uint8List`). A key bound to another account is deleted and replaced first.
 * - [METHOD_CLEAR_KEY] → null once the private key is off disk.
 *
 * The key store is opened and used on [storeDispatcher], one call at a time in the order Dart made
 * them, so a sign-out right after a sign-in cannot be overtaken by it. Methods are named
 * `adminNotice_<verb><Object>`; every refusal is a `PlatformException` code (`ERROR_*`, or
 * [INVALID_ARGUMENT]).
 *
 * It owns no channel: [BitchatFlutterChannels] offers it the methods it does not recognise.
 */
class AdminNoticeBridge(
    /** The process-wide store; opening it touches the keystore, so it is only called on [storeDispatcher]. */
    private val keyStore: () -> AdminNoticeRecipientKeyStore,
    /** Where answers are sent (the main thread); cancelled by [destroy]. */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val storeDispatcher: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1)
) : BridgeMethodHandler {

    override fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            METHOD_GET_PUBLIC_KEY -> {
                val uid = call.stringArgument("uid")?.takeIf { it.isNotEmpty() }
                    ?: return true.also { result.invalidArguments(call, "{uid: String}") }
                answer(result) { publicKeyFor(uid) }
            }
            METHOD_CLEAR_KEY -> answer(result) { clear(); null }
            else -> return false
        }
        return true
    }

    private fun answer(result: MethodChannel.Result, use: AdminNoticeRecipientKeyStore.() -> Any?) {
        scope.launch {
            val value = try {
                withContext(storeDispatcher) { keyStore().use() }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The keystore or the encrypted file failed: nothing was handed out, nothing half-done
                // is left that a retry cannot fix.
                result.error(ERROR_KEY_STORE_UNAVAILABLE, e.message, null)
                return@launch
            }
            result.success(value)
        }
    }

    /** Stops answering pending calls; the engine is going away. */
    fun destroy() {
        scope.cancel()
    }

    companion object {
        const val METHOD_GET_PUBLIC_KEY = "adminNotice_getPublicKey"
        const val METHOD_CLEAR_KEY = "adminNotice_clearKey"

        /** The encrypted key storage could not be opened, read or written. */
        const val ERROR_KEY_STORE_UNAVAILABLE = "KEY_STORE_UNAVAILABLE"
    }
}
