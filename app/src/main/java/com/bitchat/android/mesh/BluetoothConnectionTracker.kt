package com.bitchat.android.mesh

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.util.Log
import com.bitchat.android.experiment.ExperimentRecorder
import kotlinx.coroutines.CoroutineScope
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.UUID

/**
 * Tracks all Bluetooth connections and handles cleanup
 */
class BluetoothConnectionTracker(
    private val connectionScope: CoroutineScope,
    private val powerManager: PowerManager,
    /** LINK_UP / LINK_DOWN (#70): a link is up once its peer is identified, down when such a link goes away. */
    private val experimentRecorder: ExperimentRecorder = ExperimentRecorder.NoOp,
    /**
     * 量測鏈路閒置用的時鐘（P0-2）。Android 上 `System.nanoTime()` 是 CLOCK_MONOTONIC，和
     * `SystemClock.uptimeMillis()` 一樣不含深度睡眠，本機睡著的那段因此不算閒置。
     */
    private val monotonicClockMs: () -> Long = { System.nanoTime() / 1_000_000L }
) : MeshConnectionTracker(connectionScope, TAG) {
    
    companion object {
        private const val TAG = "BluetoothConnectionTracker"
    }
    
    // Connection tracking - reduced memory footprint
    private val connectedDevices = ConcurrentHashMap<String, DeviceConnection>()
    private val subscribedDevices = CopyOnWriteArrayList<BluetoothDevice>()
    val addressPeerMap = ConcurrentHashMap<String, String>()
    // Track whether we have seen the first ANNOUNCE on a given device connection
    private val firstAnnounceSeen = ConcurrentHashMap<String, Boolean>()
    // RSSI from scan results, by address and by peer: for devices we may connect as servers, and to
    // keep connected peers' strength fresh (P1-5).
    private val scanRSSI = RssiSamples()
    // 每條鏈路（以 linkID 區分 GATT 世代，位址會被重用）最後一次有動靜的時間，以 monotonicClockMs
    // 計：連上時寫入，之後每收到一個封包更新，所以就是 max(連上時間, 最後收包時間)（P0-2）。
    private val lastLinkActivityMs = ConcurrentHashMap<String, Long>()
    private val connectionStateLock = Any()
    
    /**
     * Consolidated device connection information
     */
    data class DeviceConnection(
        val device: BluetoothDevice,
        val gatt: BluetoothGatt? = null,
        val characteristic: BluetoothGattCharacteristic? = null,
        val rssi: Int = Int.MIN_VALUE,
        val isClient: Boolean = false,
        val connectedAt: Long = System.currentTimeMillis(),
        val peerID: String? = null,
        /** Unique to this GATT connection, even when Android reuses the device address. */
        val linkID: String = UUID.randomUUID().toString()
    )
    
    /** 從連線表移除的一條鏈路；[observedPeerID] 是移除當下這條鏈路已確認的 peer，沒有則為 null。 */
    data class RemovedLink(
        val deviceAddress: String,
        val connection: DeviceConnection,
        val observedPeerID: String?
    )

    /** [findIdleLinks] 找到的一條閒置鏈路；[idleForMs] 是已經多久沒有收到封包。 */
    data class IdleLink(
        val deviceAddress: String,
        val linkID: String,
        val idleForMs: Long
    )

    override fun start() {
        super.start()
    }
    
    override fun stop() {
        stopAndRemoveAll()
    }

    /**
     * 停止追蹤並清空連線表（藍牙關閉、傳輸停用、服務停止）。已確認身分的鏈路記 `LINK_DOWN`，
     * client 端的 GATT 斷線並關閉。回傳被移除的鏈路，呼叫端據此通知上層每一條斷線：藍牙關閉時
     * 堆疊不一定會送斷線回呼（試跑中 D 的殘留連線留了 28 分鐘，還擋住了重連）。
     */
    fun stopAndRemoveAll(): List<RemovedLink> {
        super.stop()
        val removed = removeAllConnections()
        // 之後不會馬上在同一個位址重連，不必等斷線回呼；scope 也可能隨即被取消，所以直接關閉。
        removed.forEach { link ->
            link.connection.gatt?.let { gatt ->
                try { gatt.disconnect() } catch (_: Exception) { }
                try { gatt.close() } catch (e: Exception) {
                    Log.w(TAG, "Error closing GATT during cleanup: ${e.message}")
                }
            }
        }
        return removed
    }

    // Abstract implementations
    override fun isConnected(id: String): Boolean = connectedDevices.containsKey(id)
    
    override fun disconnect(id: String) {
        connectedDevices[id]?.gatt?.let {
            try { it.disconnect() } catch (_: Exception) { }
        }
        cleanupDeviceConnection(id)
        Log.d(TAG, "Requested disconnect for $id")
    }

    override fun getConnectionCount(): Int = connectedDevices.size
    
    /**
     * Add a device connection
     */
    fun addDeviceConnection(deviceAddress: String, deviceConn: DeviceConnection) {
        Log.d(TAG, "Tracker: Adding device connection for $deviceAddress (isClient: ${deviceConn.isClient}")
        synchronized(connectionStateLock) {
            val replaced = connectedDevices.put(deviceAddress, deviceConn)
            if (replaced != null && replaced.linkID != deviceConn.linkID) {
                lastLinkActivityMs.remove(replaced.linkID)
            }
            lastLinkActivityMs[deviceConn.linkID] = monotonicClockMs()
            // A route observation belongs to this GATT generation, not its reusable address.
            reportLinkDown(deviceAddress, addressPeerMap.remove(deviceAddress))
        }
        removePendingConnection(deviceAddress)
        // Mark as awaiting first ANNOUNCE on this connection
        firstAnnounceSeen[deviceAddress] = false
    }
    
    /**
     * Update a device connection
     */
    fun updateDeviceConnection(deviceAddress: String, deviceConn: DeviceConnection) {
        synchronized(connectionStateLock) {
            connectedDevices[deviceAddress] = deviceConn
        }
    }

    fun updateDeviceConnectionIfCurrent(
        deviceAddress: String,
        linkID: String,
        update: (DeviceConnection) -> DeviceConnection
    ): Boolean = synchronized(connectionStateLock) {
        val current = connectedDevices[deviceAddress] ?: return@synchronized false
        if (current.linkID != linkID) return@synchronized false
        connectedDevices[deviceAddress] = update(current)
        true
    }
    
    /**
     * Get a device connection
     */
    fun getDeviceConnection(deviceAddress: String): DeviceConnection? {
        return connectedDevices[deviceAddress]
    }

    fun getCurrentLinkID(deviceAddress: String): String? =
        connectedDevices[deviceAddress]?.linkID

    /**
     * [linkID] 這條鏈路收到一個封包（P0-2）。只更新仍在連線表上的鏈路：已移除或被取代的舊 GATT
     * 晚到的封包不會讓它復活，也不會替同一位址上的新鏈路續命。
     */
    fun noteLinkReceive(linkID: String) {
        lastLinkActivityMs.replace(linkID, monotonicClockMs())
    }

    /**
     * 超過 [timeoutMs] 沒收到任何封包的鏈路（P0-2）。基準是連上的時間與最後一次收到封包的時間
     * 取較晚者，見 [LinkIdlePolicy]。
     */
    fun findIdleLinks(timeoutMs: Long = com.bitchat.android.util.AppConstants.Mesh.LINK_IDLE_TIMEOUT_MS): List<IdleLink> {
        val now = monotonicClockMs()
        return connectedDevices.mapNotNull { (address, connection) ->
            val lastActivity = lastLinkActivityMs[connection.linkID] ?: return@mapNotNull null
            if (LinkIdlePolicy.isIdle(lastActivity, now, timeoutMs)) {
                IdleLink(address, connection.linkID, now - lastActivity)
            } else {
                null
            }
        }
    }

    /**
     * Records that the current link delivered a validated, non-relayed ANNOUNCE for [peerID].
     *
     * A peer may be reachable over more than one link, so observing one link must not discard the
     * other observations. The link generation check prevents a late packet from an old GATT
     * connection from being applied to a replacement connection that reused the same address.
     */
    fun observePeerIfCurrent(deviceAddress: String, linkID: String, peerID: String): Boolean =
        synchronized(connectionStateLock) {
            if (connectedDevices[deviceAddress]?.linkID != linkID) return@synchronized false
            val previousPeer = addressPeerMap.put(deviceAddress, peerID)
            if (previousPeer != peerID) {
                reportLinkDown(deviceAddress, previousPeer)
                experimentRecorder.onLinkUp(deviceAddress, peerID)
            }
            true
        }
    
    /**
     * Get all connected devices
     */
    fun getConnectedDevices(): Map<String, DeviceConnection> {
        return connectedDevices.toMap()
    }
    
    /**
     * Get subscribed devices (for server connections)
     */
    fun getSubscribedDevices(): List<BluetoothDevice> {
        return subscribedDevices.toList()
    }
    
    /**
     * Get current RSSI for a device address
     */
    fun getDeviceRSSI(deviceAddress: String): Int? {
        return connectedDevices[deviceAddress]?.rssi?.takeIf { it != Int.MIN_VALUE }
    }
    
    /**
     * Store RSSI from scan results. Called for connected peers too: they keep advertising, and this
     * is what keeps their strength fresh. [peerID] is the one in the advertisement's service data.
     */
    fun updateScanRSSI(deviceAddress: String, rssi: Int, peerID: String? = null) {
        scanRSSI.record(deviceAddress, peerID, rssi)
    }
    
    /**
     * The freshest RSSI known for a device: the one stored on its link at connect time, or a later
     * scan of the same address or of the link's peer (an inbound link's address differs from the
     * one its peer advertises with).
     */
    fun getBestRSSI(deviceAddress: String): Int? {
        val link = connectedDevices[deviceAddress]
        val linkSample = link?.takeIf { it.rssi != Int.MIN_VALUE }?.let { RssiSamples.Sample(it.rssi, it.connectedAt) }
        val peerID = addressPeerMap[deviceAddress] ?: link?.peerID
        return RssiSamples.freshest(
            linkSample,
            scanRSSI.byAddress(deviceAddress),
            peerID?.let(scanRSSI::byPeer)
        )?.rssi
    }

    /**
     * Distinct peers on the current links (P1-5). Counts peers, not links: two phones often hold a
     * link in each role to each other. A link counts once its peer is identified, by the scan's
     * service data (outbound links) or by its first verified ANNOUNCE; a link still waiting for it
     * (the first second or so of an inbound link) does not count yet.
     */
    fun getDirectPeerCount(): Int =
        connectedDevices.entries.mapNotNullTo(HashSet()) { (address, link) -> addressPeerMap[address] ?: link.peerID }.size

    /** Whether any current link, in either role, is identified as [peerID]. */
    fun isPeerDirectlyConnected(peerID: String): Boolean =
        connectedDevices.entries.any { (address, link) -> (addressPeerMap[address] ?: link.peerID) == peerID }

    /**
     * The outbound link [getConnectionsToEvict] would give up first, with its freshest RSSI (null
     * when unknown); null without outbound links. Used to replace a weak link when full (P1-5).
     */
    fun getWeakestClientLink(): Pair<DeviceConnection, Int?>? {
        val strength = linkStrengths()
        return strength.keys.filter { it.isClient }.sortedWith(weakestFirst(strength)).firstOrNull()
            ?.let { it to strength[it] }
    }

    private fun linkStrengths(): Map<DeviceConnection, Int?> =
        connectedDevices.entries.associate { (address, link) -> link to getBestRSSI(address) }
    
    /**
     * Add a subscribed device
     */
    fun addSubscribedDevice(device: BluetoothDevice) {
        subscribedDevices.add(device)
    }
    
    /**
     * Remove a subscribed device
     */
    fun removeSubscribedDevice(device: BluetoothDevice) {
        subscribedDevices.remove(device)
    }
    
    /**
     * Check if device is already connected
     */
    fun isDeviceConnected(deviceAddress: String): Boolean = isConnected(deviceAddress)

    /**
     * Check if a peer is already connected (by PeerID)
     */
    fun isPeerConnected(peerID: String): Boolean {
        // Only consider actual connected devices that have identified themselves
        return connectedDevices.values.any { it.peerID == peerID }
    }
    
    /**
     * Disconnect a specific device (by MAC address)
     */
    fun disconnectDevice(deviceAddress: String) = disconnect(deviceAddress)
    
    /**
     * Get connected device count
     */
    fun getConnectedDeviceCount(): Int = getConnectionCount()
    
    /**
     * Check if connection limit is reached
     */
    /**
     * Check if a new client connection is allowed based on limits
     */
    fun canConnectAsClient(maxOverall: Int, maxClient: Int): Boolean {
        val total = connectedDevices.size
        val clients = connectedDevices.values.count { it.isClient }
        return total < maxOverall && clients < maxClient
    }
    
    /**
     * Calculate which connections should be evicted to satisfy limits.
     * Logic:
     * 1. Enforce strict role limits (maxClient, maxServer) - evict the weakest excess.
     * 2. Enforce overall limit (maxOverall) - evict the weakest remaining, preferring clients.
     *
     * "Weakest" is the freshest RSSI ([getBestRSSI]), oldest first on a tie; links of unknown
     * strength go after all known ones, oldest first (P1-5: upstream evicted purely the oldest).
     */
    fun getConnectionsToEvict(maxOverall: Int, maxServer: Int, maxClient: Int): List<DeviceConnection> {
        val toEvict = mutableSetOf<DeviceConnection>()
        val strength = linkStrengths()
        val evictionOrder = weakestFirst(strength)
        val currentDevices = strength.keys.toList()
        
        // 1. Enforce Role Limits
        val clients = currentDevices.filter { it.isClient }.sortedWith(evictionOrder)
        if (clients.size > maxClient) {
            toEvict.addAll(clients.take(clients.size - maxClient))
        }
        
        val servers = currentDevices.filter { !it.isClient }.sortedWith(evictionOrder)
        if (servers.size > maxServer) {
            toEvict.addAll(servers.take(servers.size - maxServer))
        }
        
        // 2. Enforce Overall Limit
        // Count how many would remain after the above evictions
        val remaining = currentDevices.filter { !toEvict.contains(it) }
        if (remaining.size > maxOverall) {
            val excessCount = remaining.size - maxOverall
            
            // Explicitly prefer evicting clients first
            val clientCandidates = remaining.filter { it.isClient }.sortedWith(evictionOrder)
            val serverCandidates = remaining.filter { !it.isClient }.sortedWith(evictionOrder)
            
            var needed = excessCount
            
            // Take from clients first
            val fromClients = clientCandidates.take(needed)
            toEvict.addAll(fromClients)
            needed -= fromClients.size
            
            // If still need more, take from servers
            if (needed > 0) {
                val fromServers = serverCandidates.take(needed)
                toEvict.addAll(fromServers)
            }
        }
        
        return toEvict.toList()
    }
    
    /** Weakest known RSSI first, oldest first on a tie; unknown strength last, oldest first. */
    private fun weakestFirst(strength: Map<DeviceConnection, Int?>): Comparator<DeviceConnection> =
        compareBy<DeviceConnection> { if (strength[it] == null) 1 else 0 }
            .thenBy { strength[it] ?: 0 }
            .thenBy { it.connectedAt }

    /**
     * Clean up a specific device connection
     */
    fun cleanupDeviceConnection(deviceAddress: String) {
        synchronized(connectionStateLock) {
            connectedDevices.remove(deviceAddress)?.let { lastLinkActivityMs.remove(it.linkID) }
            subscribedDevices.removeAll { it.address == deviceAddress }
            firstAnnounceSeen.remove(deviceAddress)
            reportLinkDown(deviceAddress, addressPeerMap.remove(deviceAddress))
        }
        Log.d(TAG, "Cleaned up device connection for $deviceAddress")
    }

    fun cleanupDeviceConnectionIfCurrent(
        deviceAddress: String,
        expectedLinkID: String
    ): Boolean = removeConnectionIfCurrent(deviceAddress, expectedLinkID) != null

    /**
     * 和 [cleanupDeviceConnectionIfCurrent] 相同，另外回傳被移除的鏈路與它已確認的 peer。peer 在
     * 同一個鎖裡取出：先讀 [addressPeerMap] 再清理的話，中間換上的新鏈路的 peer 會被當成斷線。
     */
    fun removeConnectionIfCurrent(
        deviceAddress: String,
        expectedLinkID: String
    ): RemovedLink? {
        val removed = synchronized(connectionStateLock) {
            val current = connectedDevices[deviceAddress] ?: return null
            if (current.linkID != expectedLinkID) {
                return null
            }
            if (!connectedDevices.remove(deviceAddress, current)) {
                return null
            }
            lastLinkActivityMs.remove(expectedLinkID)
            subscribedDevices.removeAll { it.address == deviceAddress }
            val observedPeerID = addressPeerMap.remove(deviceAddress)
            reportLinkDown(deviceAddress, observedPeerID)
            firstAnnounceSeen.remove(deviceAddress)
            RemovedLink(deviceAddress, current, observedPeerID)
        }
        Log.d(TAG, "Cleaned up device connection for $deviceAddress")
        return removed
    }

    /**
     * Clear all connection tracking
     */
    private fun removeAllConnections(): List<RemovedLink> {
        val removed = synchronized(connectionStateLock) {
            val links = connectedDevices.map { (address, connection) ->
                RemovedLink(address, connection, addressPeerMap[address])
            }
            addressPeerMap.forEach { (address, peer) -> reportLinkDown(address, peer) }
            connectedDevices.clear()
            lastLinkActivityMs.clear()
            subscribedDevices.clear()
            addressPeerMap.clear()
            links
        }
        pendingConnections.clear()
        scanRSSI.clear()
        firstAnnounceSeen.clear()
        return removed
    }

    /**
     * Reports the end of an identified link; a link whose peer was never identified was never up.
     * Called with [connectionStateLock] held, like `onLinkUp`, so one address's LINK_UP / LINK_DOWN
     * come out in the order its peer observations changed.
     */
    private fun reportLinkDown(deviceAddress: String, peerID: String?) {
        peerID?.let { experimentRecorder.onLinkDown(deviceAddress, it) }
    }

    /**
     * Mark that we have received the first ANNOUNCE over this device connection.
     */
    fun noteAnnounceReceived(deviceAddress: String) {
        firstAnnounceSeen[deviceAddress] = true
    }

    /**
     * Check whether the first ANNOUNCE has been seen for a device connection.
     */
    fun hasSeenFirstAnnounce(deviceAddress: String): Boolean {
        return firstAnnounceSeen[deviceAddress] == true
    }
    
    /**
     * Get debug information
     */
    fun getDebugInfo(): String {
        return buildString {
            appendLine("Connected Devices: ${connectedDevices.size} / ${powerManager.getMaxConnections()}")
            val nowMonotonic = monotonicClockMs()
            connectedDevices.forEach { (address, deviceConn) ->
                val age = (System.currentTimeMillis() - deviceConn.connectedAt) / 1000
                val idle = lastLinkActivityMs[deviceConn.linkID]?.let { "${(nowMonotonic - it) / 1000}s" } ?: "?"
                appendLine("  - $address (we're ${if (deviceConn.isClient) "client" else "server"}, ${age}s, idle $idle, RSSI: ${getBestRSSI(address)})")
            }
            appendLine()
            appendLine("Subscribed Devices (server mode): ${subscribedDevices.size}")
            appendLine()
            appendLine("Pending Connections: ${pendingConnections.size}")
            val now = System.currentTimeMillis()
            pendingConnections.forEach { (address, attempt) ->
                val elapsed = (now - attempt.lastAttempt) / 1000
                appendLine("  - $address: ${attempt.attempts} attempts, last ${elapsed}s ago")
            }
            appendLine()
            val scanned = scanRSSI.addressSnapshot()
            appendLine("Scan RSSI Cache: ${scanned.size}")
            scanned.forEach { (address, rssi) ->
                appendLine("  - $address: $rssi dBm")
            }
        }
    }
} 
