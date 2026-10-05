package com.bitchat.android.experiment

import com.bitchat.android.protocol.BitchatPacket

/**
 * 實機量測（#70）在 BLE mesh 路徑上的插入點。
 *
 * 插入點只把手上現成的資料原樣交過來（封包、BLE 鏈路位址、寫出的鏈路數），不查表、不格式化：
 * release build 拿到的是 [NoOp]，production 路徑因此只多一次空呼叫。debug build 由
 * `ExperimentTools` 換成輸出 `CARES_EXP` log 與 `exp.csv` 的實作，查上一跳 peer、電源模式、
 * 直連數等都在那裡做。
 */
interface ExperimentRecorder {

    /** `RX`：第一次收到 [packet]，已通過去重與簽章驗證。[ingressAddress] 是送來的那條 BLE 鏈路。 */
    fun onReceived(packet: BitchatPacket, ingressAddress: String?)

    /**
     * `DUP`：[packet] 已經收過（自己發出的封包不算）。只比對 message ID、不驗簽章。通常隨即丟棄；
     * 直連的 ANNOUNCE 例外會在驗簽後再處理一次，也記 `DUP`，所以 `RX` 每個封包只有一列。
     */
    fun onDuplicate(packet: BitchatPacket, ingressAddress: String?)

    /**
     * `TX`／`RELAY`：[packet] 已交給 [fanout] 條 BLE 鏈路的送出佇列（可能是 0），[wireBytes] 是
     * 線路上的位元組數。發送者是自己即 `TX`，否則是 `RELAY`。
     *
     * 在實際寫出鏈路的地方記，而不是在 Relay Decision 或實驗發送器那裡：廣播經 actor 非同步送出，
     * 只有這裡知道寫出了幾條鏈路。因此 `TX` 涵蓋本機發出的每個廣播（ANNOUNCE 等也算），分析時
     * 以 `type` 篩選。
     */
    fun onBroadcastWritten(packet: BitchatPacket, wireBytes: Int, fanout: Int)

    /** `QFULL`：[deviceAddress] 這條鏈路的送出佇列已滿，[data]（線路上的封包）被拒收。 */
    fun onSendQueueFull(deviceAddress: String, data: ByteArray)

    /** `LINK_UP`：直連 [deviceAddress] 確認對面是 [peerID]。 */
    fun onLinkUp(deviceAddress: String, peerID: String)

    /** `LINK_DOWN`：已確認是 [peerID] 的直連 [deviceAddress] 中斷。 */
    fun onLinkDown(deviceAddress: String, peerID: String)

    /**
     * `RSSI`：掃描收到 [deviceAddress] 的廣播，訊號強度 [rssi]（dBm）。[peerID] 取自掃描回應的
     * service data，沒有時為 null。程式不讀連線中的 RSSI，對方廣播在本機收到的強度就是
     * 「本機收對方」這個方向的量測；連上線之後對方仍持續廣播，所以也量得到。
     */
    fun onScanRssi(peerID: String?, deviceAddress: String, rssi: Int)

    /** release build 與未安裝實驗工具時的實作：什麼都不做。 */
    object NoOp : ExperimentRecorder {
        override fun onReceived(packet: BitchatPacket, ingressAddress: String?) = Unit
        override fun onDuplicate(packet: BitchatPacket, ingressAddress: String?) = Unit
        override fun onBroadcastWritten(packet: BitchatPacket, wireBytes: Int, fanout: Int) = Unit
        override fun onSendQueueFull(deviceAddress: String, data: ByteArray) = Unit
        override fun onLinkUp(deviceAddress: String, peerID: String) = Unit
        override fun onLinkDown(deviceAddress: String, peerID: String) = Unit
        override fun onScanRssi(peerID: String?, deviceAddress: String, rssi: Int) = Unit
    }
}
