package com.bitchat.android.gateway

import android.util.Log
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * 物資封包的 Gateway：已登入、有網路的手機，把經 mesh 收到、驗證通過的別人的物資需求／捐贈
 * 寫進 Firestore 的 `mesh_supply_packets/{packetId}`，給管理後台調度物資用。
 *
 * 結構與 [MeshGateway] 相同：輸入只有 [onPacket]、[onNetworkChanged]、[onSignedIn]、
 * [onEnabledChanged]，依到達順序在單一 coroutine 處理；輸出只有注入的 [uploader]。跟著同一個
 * 「代傳附近的求救與回報」開關（#113）。
 *
 * 與 Health Report 不同的是去重的鍵：物資封包是事件、不是狀態，同一個人可以送很多筆，所以以
 * Packet ID 為單位，每筆只傳一次；規則不允許 update，別的 Gateway 先寫到就得到 PERMISSION_DENIED，
 * 視同已上傳。
 *
 * 上傳條件：開關開啟、已登入、封包年齡不超過 [retentionMs] 且標頭時間不比現在晚 10 分鐘以上、
 * 這個 Packet ID 還沒傳過。沒網路或暫時性錯誤時暫存在記憶體（不寫磁碟），網路恢復、登入或下一筆
 * 即時上傳成功時補傳。
 */
class MeshSupplyGateway(
    private val uploader: MeshSupplyUploader,
    private val nowMs: () -> Long,
    scope: CoroutineScope,
    private val retentionMs: Long = AppConstants.Sync.HEALTH_REPORT_RETENTION_MS,
    private val maxHeldPackets: Int = MAX_HELD_PACKETS
) {
    private sealed interface Input {
        class Packet(val packet: GatewaySupplyPacket) : Input
        class Network(val available: Boolean) : Input
        class Account(val uid: String?) : Input
        class Enabled(val enabled: Boolean) : Input
    }

    private val inputs = Channel<Input>(Channel.UNLIMITED)

    private var enabled = true
    private var online = false
    private var gatewayUid: String? = null
    private var lastSignedInUid: String? = null

    /** Packet ID → 上傳（或確認已在 Firestore 上）時的 createdAt，過期後忘掉。 */
    private val uploaded = HashMap<String, Long>()

    /** 等著上傳的封包：Packet ID → 封包，依收到順序。 */
    private val held = LinkedHashMap<String, GatewaySupplyPacket>()

    init {
        scope.launch {
            for (input in inputs) handle(input)
        }
    }

    fun onPacket(packet: GatewaySupplyPacket) {
        inputs.trySend(Input.Packet(packet))
    }

    fun onNetworkChanged(available: Boolean) {
        inputs.trySend(Input.Network(available))
    }

    fun onSignedIn(uid: String?) {
        inputs.trySend(Input.Account(uid))
    }

    fun onEnabledChanged(enabled: Boolean) {
        inputs.trySend(Input.Enabled(enabled))
    }

    fun stop() {
        inputs.close()
    }

    private suspend fun handle(input: Input) {
        when (input) {
            is Input.Packet -> consider(input.packet)
            is Input.Network -> {
                val reconnected = input.available && !online
                online = input.available
                if (reconnected) catchUp()
            }
            is Input.Account -> {
                gatewayUid = input.uid
                if (input.uid != null) {
                    if (lastSignedInUid != null && input.uid != lastSignedInUid) held.clear()
                    lastSignedInUid = input.uid
                    catchUp()
                }
            }
            is Input.Enabled -> {
                enabled = input.enabled
                if (enabled) catchUp() else held.clear()
            }
        }
    }

    private suspend fun consider(packet: GatewaySupplyPacket) {
        if (!enabled) return
        val uid = gatewayUid ?: return
        forgetExpired()
        if (!isFresh(packet) || uploaded.containsKey(packet.packetId)) return
        if (!online) {
            hold(packet)
        } else if (upload(packet, uid)) {
            catchUp()
        }
    }

    private suspend fun catchUp() {
        val uid = gatewayUid ?: return
        if (!enabled || !online) return
        forgetExpired()
        for (packet in held.values.toList()) {
            if (!upload(packet, uid)) break
        }
    }

    /** 回傳是否該繼續上傳下一筆。 */
    private suspend fun upload(packet: GatewaySupplyPacket, uid: String): Boolean {
        when (uploader.upload(packet, uid)) {
            UploadResult.UPLOADED -> markUploaded(packet)
            UploadResult.PERMISSION_DENIED -> {
                Log.i(TAG, "Firestore refused supply packet ${packet.packetId.take(8)}; counting it as already uploaded")
                markUploaded(packet)
            }
            UploadResult.TRANSIENT_FAILURE -> {
                Log.w(TAG, "Supply packet ${packet.packetId.take(8)} not uploaded; held for the next network event")
                hold(packet)
                return false
            }
        }
        return true
    }

    private fun hold(packet: GatewaySupplyPacket) {
        if (held.containsKey(packet.packetId)) return
        held[packet.packetId] = packet
        if (held.size > maxHeldPackets) {
            held.remove(held.keys.first())
        }
    }

    /**
     * 標頭時間是發送者的時鐘。比現在晚超過 [MAX_FUTURE_SKEW_MS] 的封包 firestore.rules 也不收，
     * 遠在未來的連 Firestore Timestamp 都建不出來；若暫存起來，[forgetExpired] 永遠清不掉它，
     * 每次 [catchUp] 都會卡在它前面。
     */
    private fun isFresh(packet: GatewaySupplyPacket): Boolean {
        val ageMs = nowMs() - packet.createdAtMs
        return ageMs >= -MAX_FUTURE_SKEW_MS && ageMs <= retentionMs
    }

    private fun markUploaded(packet: GatewaySupplyPacket) {
        uploaded[packet.packetId] = packet.createdAtMs
        held.remove(packet.packetId)
    }

    private fun forgetExpired() {
        val oldestFresh = nowMs() - retentionMs
        held.values.removeAll { it.createdAtMs < oldestFresh }
        uploaded.values.removeAll { it < oldestFresh }
    }

    private companion object {
        const val TAG = "MeshSupplyGateway"
        const val MAX_HELD_PACKETS = 1_000

        /** 與 firestore.rules 的 `createdAt <= request.time + 10m` 相同。 */
        const val MAX_FUTURE_SKEW_MS = 10 * 60 * 1000L
    }
}
