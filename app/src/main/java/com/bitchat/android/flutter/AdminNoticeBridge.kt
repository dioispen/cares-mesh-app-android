package com.bitchat.android.flutter

import android.util.Log
import com.bitchat.android.adminnotice.AdminNoticeChangeListener
import com.bitchat.android.adminnotice.AdminNoticeKind
import com.bitchat.android.adminnotice.AdminNoticeLevel
import com.bitchat.android.adminnotice.AdminNoticeStatus
import com.bitchat.android.adminnotice.AdminNoticeStore
import com.bitchat.android.adminnotice.StoredAdminNotice
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
 * The Admin Notice half of the Flutter bridge (docs/ADMIN_NOTICE_V1.md 收件者加密金鑰, 收件端呈現).
 *
 * The recipient key (#140): Flutter registers this device's public key with the Reporter Handle
 * registration and asks for it to be deleted on sign-out and emergency clear.
 * - [METHOD_GET_PUBLIC_KEY] `{uid: String}` → the 32-byte public key bound to `uid` (a Dart
 *   `Uint8List`). A key bound to another account is deleted and replaced first.
 * - [METHOD_CLEAR_KEY] → null once the private key is off disk.
 *
 * The notice list (#142), read from the process-wide [AdminNoticeStore] the Inbox's presenter
 * writes:
 * - [METHOD_GET_ALL] → every notice still kept (until 7 days after its expiresAt), newest first,
 *   each as [toBridgeMap] describes.
 * - [METHOD_MARK_READ] `{messageId: String}` → null once it is marked read (also when it was
 *   already read or is gone). Its first reading goes to [onFirstRead].
 * - Event [EVENT_ADMIN_NOTICE] `{type, notices: List<Map>}`: the whole list again, as
 *   [METHOD_GET_ALL] answers, whenever a notice is stored or changes. Only while this engine is
 *   attached; a notice arriving without one is in the list Dart reads next time.
 *
 * Both stores are used on [storeDispatcher], one call at a time in the order Dart made them, so a
 * sign-out right after a sign-in cannot be overtaken by it, and a list answered or pushed is never
 * older than one Dart received before it. Methods are named `adminNotice_<verb><Object>`; every
 * refusal is a `PlatformException` code (`ERROR_*`, or [INVALID_ARGUMENT]).
 *
 * It owns no channel: [BitchatFlutterChannels] offers it the methods it does not recognise.
 */
class AdminNoticeBridge(
    /** The process-wide store; opening it touches the keystore, so it is only called on [storeDispatcher]. */
    private val keyStore: () -> AdminNoticeRecipientKeyStore,
    /** The process-wide notice store; it opens its encrypted file on first use, on [storeDispatcher]. */
    private val notices: AdminNoticeStore,
    private val events: BridgeEventEmitter,
    /**
     * The first time the user reads a notice in the App, on [storeDispatcher] with its readAt set.
     * #143 writes the readAt receipt of a targeted notice here; it must not block.
     */
    private val onFirstRead: (StoredAdminNotice) -> Unit = {},
    /** Where answers are sent (the main thread); cancelled by [destroy]. */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val storeDispatcher: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1)
) : BridgeMethodHandler {

    private val noticesChanged = AdminNoticeChangeListener { pushNotices() }

    init {
        notices.addChangeListener(noticesChanged)
    }

    override fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            METHOD_GET_PUBLIC_KEY -> {
                val uid = call.stringArgument("uid")?.takeIf { it.isNotEmpty() }
                    ?: return true.also { result.invalidArguments(call, "{uid: String}") }
                answer(result, ERROR_KEY_STORE_UNAVAILABLE) { keyStore().publicKeyFor(uid) }
            }
            METHOD_CLEAR_KEY -> answer(result, ERROR_KEY_STORE_UNAVAILABLE) { keyStore().clear(); null }
            METHOD_GET_ALL -> answer(result, ERROR_NOTICE_STORE_UNAVAILABLE) { noticeList() }
            METHOD_MARK_READ -> {
                val messageId = call.stringArgument("messageId")?.takeIf { it.isNotEmpty() }
                    ?: return true.also { result.invalidArguments(call, "{messageId: String}") }
                answer(result, ERROR_NOTICE_STORE_UNAVAILABLE) {
                    notices.markRead(messageId)?.let(::firstRead)
                    null
                }
            }
            else -> return false
        }
        return true
    }

    private fun noticeList(): List<Map<String, Any?>> = notices.all().map { it.toBridgeMap() }

    private fun firstRead(notice: StoredAdminNotice) {
        try {
            onFirstRead(notice)
        } catch (e: Exception) {
            // The reading is on disk; a receipt that could not be queued must not undo it for Dart.
            Log.w(TAG, "First reading of Admin Notice ${notice.messageId} not passed on: ${e.message}")
        }
    }

    /** Answers [result] with [use]'s value, run on [storeDispatcher]; a store failure is [errorCode]. */
    private fun answer(result: MethodChannel.Result, errorCode: String, use: () -> Any?) {
        scope.launch {
            val value = try {
                withContext(storeDispatcher) { use() }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The keystore or the encrypted file failed: nothing was handed out, nothing half-done
                // is left that a retry cannot fix.
                result.error(errorCode, e.message, null)
                return@launch
            }
            result.success(value)
        }
    }

    /** Reads the list on [storeDispatcher], never on the writer's thread (the Inbox holds its lock). */
    private fun pushNotices() {
        scope.launch {
            val list = try {
                withContext(storeDispatcher) { noticeList() }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Admin Notice list not pushed: ${e.message}")
                return@launch
            }
            events.emit(mapOf("type" to EVENT_ADMIN_NOTICE, "notices" to list))
        }
    }

    /** Stops answering pending calls and pushing changes; the engine is going away. */
    fun destroy() {
        notices.removeChangeListener(noticesChanged)
        scope.cancel()
    }

    companion object {
        private const val TAG = "AdminNoticeBridge"

        const val METHOD_GET_PUBLIC_KEY = "adminNotice_getPublicKey"
        const val METHOD_CLEAR_KEY = "adminNotice_clearKey"
        const val METHOD_GET_ALL = "adminNotice_getAll"
        const val METHOD_MARK_READ = "adminNotice_markRead"

        /** `{type, notices: List<Map>}`: the notice list, pushed whenever it changes. */
        const val EVENT_ADMIN_NOTICE = "admin_notice"

        /** The encrypted key storage could not be opened, read or written. */
        const val ERROR_KEY_STORE_UNAVAILABLE = "KEY_STORE_UNAVAILABLE"

        /** The encrypted notice storage could not be opened, read or written. */
        const val ERROR_NOTICE_STORE_UNAVAILABLE = "NOTICE_STORE_UNAVAILABLE"
    }
}

/**
 * One notice as Dart's list reads it. 已過期 is not here: Dart derives it from `expiresAt` with
 * its own clock, so the label appears while the screen stays open. `replacedBy` is the notice
 * that corrected this one; `content` is sent even for a corrected or withdrawn notice, which the
 * screen does not show.
 */
internal fun StoredAdminNotice.toBridgeMap(): Map<String, Any?> = mapOf(
    "messageId" to messageId,
    "kind" to when (kind) {
        AdminNoticeKind.BROADCAST -> "broadcast"
        AdminNoticeKind.TARGETED -> "targeted"
    },
    "level" to when (level) {
        AdminNoticeLevel.INFO -> "info"
        AdminNoticeLevel.IMPORTANT -> "important"
        AdminNoticeLevel.URGENT -> "urgent"
    },
    "content" to content,
    "issuedAt" to issuedAtMs,
    "expiresAt" to expiresAtMs,
    "status" to when (status) {
        AdminNoticeStatus.ACTIVE -> "active"
        AdminNoticeStatus.CORRECTED -> "corrected"
        AdminNoticeStatus.WITHDRAWN -> "withdrawn"
    },
    "replacedBy" to replacedBy,
    "read" to isRead
)
