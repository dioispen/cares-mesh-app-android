package com.bitchat.android.mesh

import android.util.Log
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.protocol.SupplyExchangePacket
import java.util.concurrent.CopyOnWriteArraySet

/**
 * 一筆通過 MessageHandler 檢查的物資需求／捐贈：簽章驗過（已驗證的在線 peer）、payload 解得開。
 * 即時 flood 與 gossip sync 補送的都走這裡。
 */
class VerifiedSupplyExchange(
    /** 收到時的 SUPPLY_EXCHANGE 封包，簽章與線路編碼完整，日後可以重新驗簽。 */
    val packet: BitchatPacket,
    val supply: SupplyExchangePacket,
    val senderPeerID: String
)

/**
 * 把驗過的物資封包交給 Gateway 的 process-wide hook，比照 [VerifiedHealthReportBridge]：
 * 放在 `mesh/`，協定層不依賴 Firebase，由 Gateway 來這裡登記。
 *
 * Listener 在 MessageHandler 的 coroutine 上執行，必須很快返回。
 */
object VerifiedSupplyExchangeBridge {
    private const val TAG = "VerifiedSupplyExchangeBridge"

    private val listeners = CopyOnWriteArraySet<(VerifiedSupplyExchange) -> Unit>()

    fun addListener(listener: (VerifiedSupplyExchange) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (VerifiedSupplyExchange) -> Unit) {
        listeners.remove(listener)
    }

    /** 給測試用：停掉的 Gateway 若留下 listener 就是漏了。 */
    internal val listenerCount: Int get() = listeners.size

    /** 由 MessageHandler 呼叫。某個 listener 失敗不能影響 mesh 處理封包。 */
    internal fun publish(supply: VerifiedSupplyExchange) {
        listeners.forEach { listener ->
            try {
                listener(supply)
            } catch (e: Exception) {
                Log.w(TAG, "Supply exchange listener failed: ${e.message}")
            }
        }
    }
}
