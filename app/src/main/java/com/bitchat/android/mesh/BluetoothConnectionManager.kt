package com.bitchat.android.mesh

import android.bluetooth.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import androidx.core.content.ContextCompat
import com.bitchat.android.experiment.ExperimentRecorder
import com.bitchat.android.model.RoutedPacket
import com.bitchat.android.protocol.BitchatPacket
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Power-optimized Bluetooth connection manager with comprehensive memory management
 * Integrates with PowerManager for adaptive power consumption
 * Coordinates smaller, focused components for better maintainability
 */
class BluetoothConnectionManager(
    private val context: Context, 
    private val myPeerID: String,
    private val fragmentManager: FragmentManager? = null,
    private val experimentRecorder: ExperimentRecorder = ExperimentRecorder.NoOp
) {
    
    companion object {
        private const val TAG = "BluetoothConnectionManager"
        // binder 失效後先拆掉元件，隔一段時間再重建；連續失效時加倍，最多到 64 s。
        private const val RADIO_RESTART_DELAY_MS = 2_000L
        private const val MAX_RADIO_RESTART_BACKOFF_SHIFT = 5
        // 藍牙已開啟、元件卻啟動失敗（例如 advertiser 一時還拿不到）時的重試。
        private const val RADIO_START_RETRY_DELAY_MS = 3_000L
        private const val MAX_RADIO_START_RETRIES = 3
        private const val CLEANUP_DELAY = com.bitchat.android.util.AppConstants.Mesh.CONNECTION_CLEANUP_DELAY_MS
    }
    
    // Core Bluetooth components
    private val bluetoothManager: BluetoothManager = 
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private val appContext: Context = context.applicationContext ?: context
    
    // Power management
    private val powerManager = PowerManager.getInstance(context.applicationContext)
    
    // Coroutines
    private val connectionScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // Component managers
    private val permissionManager = BluetoothPermissionManager(context)
    private val connectionTracker = BluetoothConnectionTracker(connectionScope, powerManager, experimentRecorder)
    private val packetBroadcaster = BluetoothPacketBroadcaster(
        connectionScope,
        connectionTracker,
        fragmentManager,
        myPeerID,
        experimentRecorder,
        isAdapterOn = ::isAdapterOn,
        onLinkStalled = { address, linkID -> disconnectLinkLocally(address, linkID, "writes refused") },
        onBluetoothFault = ::onBluetoothFault
    )
    
    // Delegate for component managers to call back to main manager
    private val componentDelegate = object : BluetoothConnectionManagerDelegate {
        override fun onPacketReceived(
            packet: BitchatPacket,
            peerID: String,
            device: BluetoothDevice?,
            ingressLinkID: String
        ) {
            device?.let { bluetoothDevice ->
                // Get current RSSI for this device and update if available
                val currentRSSI = connectionTracker.getBestRSSI(bluetoothDevice.address)
                if (currentRSSI != null) {
                    delegate?.onRSSIUpdated(bluetoothDevice.address, currentRSSI)
                }
            }

            if (peerID == myPeerID) return // Ignore messages from self

            delegate?.onPacketReceived(packet, peerID, device, ingressLinkID)
        }
        
        override fun onDeviceConnected(device: BluetoothDevice) {
            // Trigger limit enforcement immediately upon any new connection
            enforceStrictLimits()
            delegate?.onDeviceConnected(device)
        }

        override fun onDeviceDisconnected(device: BluetoothDevice, linkID: String?, peerID: String?) {
            packetBroadcaster.onLinkDisconnected(device.address, linkID)
            delegate?.onDeviceDisconnected(device, linkID, peerID)
        }

        override fun onGattClientWriteComplete(deviceAddress: String, linkID: String, status: Int) {
            packetBroadcaster.onGattClientWriteComplete(deviceAddress, linkID, status)
        }

        override fun onGattServerNotificationComplete(deviceAddress: String, linkID: String?, status: Int) {
            packetBroadcaster.onGattServerNotificationComplete(deviceAddress, linkID, status)
        }
        
        override fun onRSSIUpdated(deviceAddress: String, rssi: Int) {
            delegate?.onRSSIUpdated(deviceAddress, rssi)
        }
    }
    
    private val serverManager = BluetoothGattServerManager(
        context, connectionScope, connectionTracker, permissionManager, powerManager, componentDelegate, myPeerID
    )
    private val clientManager = BluetoothGattClientManager(
        context, connectionScope, connectionTracker, permissionManager, powerManager, componentDelegate, experimentRecorder
    )
    
    // Service state
    // mesh 要 BLE 運作：startServices() 之後、disableTransport()／stopServices() 之前。藍牙關閉期間
    // 仍為 true，藍牙重新開啟時據此重建元件（P0-1）。
    private var isActive = false
    
    // BLE 元件（GATT server／client、掃描、廣播）是否已為這一次藍牙開啟啟動。啟動與拆除都在
    // radioMutex 裡依 BluetoothRadioPolicy 決定。
    @Volatile private var radioRunning = false
    // 每次啟動加一；binder 失效的回報只對回報當下那一代有效，同一次失效不會讓元件重建好幾次。
    @Volatile private var radioGeneration = 0
    @Volatile private var radioStartRetries = 0
    @Volatile private var radioFaultRestarts = 0
    private val radioMutex = Mutex()

    private val adapterReceiverRegistered = AtomicBoolean(false)
    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            val stateName = adapterStateName(state)
            Log.i(TAG, "Bluetooth adapter state changed: $stateName")
            // 使用者切換藍牙是新的開始，之前累積的重試與退避都歸零。
            radioStartRetries = 0
            radioFaultRestarts = 0
            connectionScope.launch { reconcileRadio("adapter $stateName") }
        }
    }
    
    // Delegate for callbacks
    var delegate: BluetoothConnectionManagerDelegate? = null
    
    // Public property for address-peer mapping
    val addressPeerMap get() = connectionTracker.addressPeerMap

    fun observePeerIfCurrent(deviceAddress: String, linkID: String, peerID: String): Boolean =
        connectionTracker.observePeerIfCurrent(deviceAddress, linkID, peerID)

    fun getCurrentLinkID(deviceAddress: String): String? =
        connectionTracker.getCurrentLinkID(deviceAddress)

    private fun isBleTransportEnabled(): Boolean {
        return try {
            com.bitchat.android.ui.debug.DebugSettingsManager.getInstance().bleEnabled.value
        } catch (_: Exception) {
            try { com.bitchat.android.ui.debug.DebugPreferenceManager.getBleEnabled(true) } catch (_: Exception) { true }
        }
    }

    private fun isGattServerEnabled(): Boolean {
        return isBleTransportEnabled() &&
            (try { com.bitchat.android.ui.debug.DebugSettingsManager.getInstance().gattServerEnabled.value } catch (_: Exception) { true })
    }

    private fun isGattClientEnabled(): Boolean {
        return isBleTransportEnabled() &&
            (try { com.bitchat.android.ui.debug.DebugSettingsManager.getInstance().gattClientEnabled.value } catch (_: Exception) { true })
    }

    init {
        connectionScope.launch {
            var previousMode: PowerManager.PowerMode? = null
            powerManager.profile.collect { profile ->
                val modeChanged = previousMode != null && previousMode != profile.mode
                previousMode = profile.mode
                if (!isActive || !isBleTransportEnabled() || !radioRunning) return@collect

                if (modeChanged && isGattServerEnabled()) {
                    serverManager.restartAdvertising()
                }
                clientManager.applyPowerProfile(profile)
            }
        }
        // Observe debug settings to enforce role state while active
        try {
            val dbg = com.bitchat.android.ui.debug.DebugSettingsManager.getInstance()
            // Master transport enable/disable
            connectionScope.launch {
                dbg.bleEnabled.collect { enabled ->
                    if (enabled) return@collect
                    if (isActive) {
                        disableTransport()
                    }
                }
            }
            // Role enable/disable
            connectionScope.launch {
                dbg.gattServerEnabled.collect { enabled ->
                    if (!isActive) return@collect
                    if (enabled && isBleTransportEnabled()) startServer() else stopServer()
                }
            }
            connectionScope.launch {
                dbg.gattClientEnabled.collect { enabled ->
                    if (!isActive) return@collect
                    if (enabled && isBleTransportEnabled()) startClient() else stopClient()
                }
            }
            
            // Centralized limit enforcement on any setting change
            connectionScope.launch {
                combine(
                    dbg.maxConnectionsOverall,
                    dbg.maxServerConnections,
                    dbg.maxClientConnections
                ) { _, _, _ -> 
                    // We don't need the values here, we just need to trigger enforcement
                    Unit 
                }.collect {
                    if (isActive) {
                        enforceStrictLimits()
                    }
                }
            }
        } catch (_: Exception) { }
    }
    
    /**
     * Centralized connection limit enforcement
     */
    private fun enforceStrictLimits() {
        if (!isActive) return
        
        try {
            val dbg = com.bitchat.android.ui.debug.DebugSettingsManager.getInstance()
            val maxOverall = dbg.maxConnectionsOverall.value
            val maxServer = dbg.maxServerConnections.value
            val maxClient = dbg.maxClientConnections.value
            
            // Get list of connections to evict to satisfy all constraints
            val toEvict = connectionTracker.getConnectionsToEvict(maxOverall, maxServer, maxClient)
            
            if (toEvict.isNotEmpty()) {
                Log.i(TAG, "Enforcing limits (max: $maxOverall, s: $maxServer, c: $maxClient) - evicting ${toEvict.size} connections")
                
                toEvict.forEach { conn ->
                    if (conn.isClient) {
                        try { conn.gatt?.disconnect() } catch (_: Exception) { }
                    } else {
                        serverManager.disconnectDevice(conn.device)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error enforcing limits: ${e.message}")
        }
    }
    
    /**
     * Start all Bluetooth services with power optimization
     *
     * 藍牙關閉時也回傳 true：mesh 進入「等藍牙開啟」，[adapterStateReceiver] 收到 `STATE_ON` 後才啟動
     * GATT 與掃描廣播。和執行中關閉藍牙是同一個狀態，之後開啟藍牙都會自動入網。
     */
    fun startServices(): Boolean {
        if (!isBleTransportEnabled()) {
            Log.i(TAG, "BLE transport disabled by debug settings; not starting Bluetooth services")
            disableTransport()
            return false
        }
        
        if (!permissionManager.hasBluetoothPermissions()) {
            Log.e(TAG, "Missing Bluetooth permissions")
            return false
        }
        
        if (!connectionScope.isActive) {
            Log.e(TAG, "Connection manager was stopped; create a new instance instead of restarting")
            return false
        }

        // set the adapter's name to our 8-character peerID for iOS privacy, TODO: Make this configurable
        // try {
        //     if (bluetoothAdapter?.name != myPeerID) {
        //         bluetoothAdapter?.name = myPeerID
        //         Log.d(TAG, "Set Bluetooth adapter name to peerID: $myPeerID for iOS compatibility.")
        //     }
        // } catch (se: SecurityException) {
        //     Log.e(TAG, "Missing BLUETOOTH_CONNECT permission to set adapter name.", se)
        // }

        isActive = true
        radioStartRetries = 0
        radioFaultRestarts = 0
        registerAdapterStateReceiver()
        if (!isAdapterOn()) {
            Log.i(TAG, "Bluetooth is not enabled; Bluetooth services will start when it turns on")
        }
        connectionScope.launch { reconcileRadio("start requested") }
        return true
    }

    /**
     * Disable BLE without cancelling this manager's coroutine scope, so it can be re-enabled.
     */
    fun disableTransport() {
        Log.i(TAG, "Disabling BLE transport")
        isActive = false
        connectionScope.launch { reconcileRadio("transport disabled") }
    }
    
    /**
     * Stop all Bluetooth services with proper cleanup
     */
    fun stopServices() {
        isActive = false
        unregisterAdapterStateReceiver()

        connectionScope.launch {
            // Stop component managers and the connection tracker
            radioMutex.withLock { stopRadio("services stopped") }
            
            // Cancel the coroutine scope
            connectionScope.cancel()
            
            Log.i(TAG, "All Bluetooth services stopped")
        }
    }

    /**
     * 依目前狀態啟動或拆掉 BLE 元件。藍牙狀態改變、啟動或停用傳輸、GATT 呼叫發現 binder 失效時都
     * 走這裡；每次都重新讀取轉接器狀態，事件晚到或順序顛倒也會收斂到正確的結果。
     *
     * @param faultedGeneration binder 失效時回報當下的 [radioGeneration]；那一代已經拆掉就忽略。
     */
    private suspend fun reconcileRadio(reason: String, faultedGeneration: Int? = null) {
        var restartDelayMs = 0L
        radioMutex.withLock {
            val faulted = faultedGeneration != null
            if (faulted && (faultedGeneration != radioGeneration || !radioRunning)) return

            val action = BluetoothRadioPolicy.decide(
                running = radioRunning,
                requested = isActive,
                transportEnabled = isBleTransportEnabled(),
                adapterOn = isAdapterOn(),
                faulted = faulted
            )
            when (action) {
                BluetoothRadioPolicy.Action.NONE -> Unit
                BluetoothRadioPolicy.Action.START -> {
                    if (startRadio()) {
                        radioStartRetries = 0
                    } else {
                        scheduleRadioStartRetry()
                    }
                }
                BluetoothRadioPolicy.Action.STOP -> {
                    stopRadio(reason)
                    if (faulted) {
                        val shift = radioFaultRestarts.coerceAtMost(MAX_RADIO_RESTART_BACKOFF_SHIFT)
                        radioFaultRestarts++
                        restartDelayMs = RADIO_RESTART_DELAY_MS shl shift
                    }
                }
            }
        }
        if (restartDelayMs > 0L) {
            Log.w(TAG, "Bluetooth services torn down after a fault; rebuilding in ${restartDelayMs}ms")
            delay(restartDelayMs)
            reconcileRadio("rebuild after fault")
        }
    }

    /** 在 [radioMutex] 裡呼叫。任一元件啟動失敗就整組拆掉，回傳 false。 */
    private fun startRadio(): Boolean {
        radioGeneration++

        // Start connection tracker first
        connectionTracker.start()

        // Start power manager
        powerManager.start()

        // Start server/client based on debug settings
        if (isGattServerEnabled()) {
            if (!serverManager.start()) {
                Log.e(TAG, "Failed to start server manager")
                stopRadio("server manager failed to start")
                return false
            }
        } else {
            Log.i(TAG, "GATT Server disabled by debug settings; not starting")
        }

        if (isGattClientEnabled()) {
            if (!clientManager.start()) {
                Log.e(TAG, "Failed to start client manager")
                stopRadio("client manager failed to start")
                return false
            }
        } else {
            Log.i(TAG, "GATT Client disabled by debug settings; not starting")
        }

        radioRunning = true
        Log.i(TAG, "Bluetooth services started successfully")
        return true
    }

    /**
     * 在 [radioMutex] 裡呼叫。停掉掃描、廣播與 GATT server，丟掉每條鏈路的待送佇列，清空連線表，
     * 並對每一條被移除的鏈路通知上層斷線（試跑中 D 關藍牙後一直沒有 `LINK_DOWN`，殘留連線還讓
     * 掃描結果被當成「已連上」而跳過）。之後不再對這一代的 GATT 物件發出任何呼叫。
     */
    private fun stopRadio(reason: String) {
        Log.i(TAG, "Stopping Bluetooth services ($reason)")
        radioRunning = false
        clientManager.stop()
        serverManager.stop()
        packetBroadcaster.clearPendingSends()
        connectionTracker.stopAndRemoveAll().forEach { link ->
            componentDelegate.onDeviceDisconnected(
                link.connection.device,
                link.connection.linkID,
                link.observedPeerID
            )
        }
    }

    private fun scheduleRadioStartRetry() {
        if (radioStartRetries >= MAX_RADIO_START_RETRIES) {
            Log.e(TAG, "Bluetooth services failed to start after $radioStartRetries retries; waiting for the next adapter state change")
            return
        }
        radioStartRetries++
        val attempt = radioStartRetries
        connectionScope.launch {
            delay(RADIO_START_RETRY_DELAY_MS)
            reconcileRadio("start retry $attempt")
        }
    }

    /** 送出時發現 binder 已失效，或轉接器不是 ON 時寫入被拒：當作藍牙已重啟，走同一套流程。 */
    private fun onBluetoothFault(reason: String) {
        val generation = radioGeneration
        connectionScope.launch { reconcileRadio("Bluetooth fault: $reason", faultedGeneration = generation) }
    }

    /**
     * 在本機立刻拆掉 [linkID] 這一條鏈路，不等藍牙堆疊的斷線回呼：從連線表移除（只移除仍是這一代
     * 的項目）、通知上層、請堆疊斷線並關閉 GATT。舊 GATT 晚到的回呼經 `*IfCurrent` 檢查後不會
     * 動到同一位址上的新鏈路。
     */
    private fun disconnectLinkLocally(deviceAddress: String, linkID: String, reason: String) {
        val removed = connectionTracker.removeConnectionIfCurrent(deviceAddress, linkID) ?: return
        Log.w(TAG, "Dropping link $deviceAddress ($reason)")
        val connection = removed.connection
        componentDelegate.onDeviceDisconnected(connection.device, linkID, removed.observedPeerID)
        if (connection.isClient) {
            val gatt = connection.gatt ?: return
            try { gatt.disconnect() } catch (_: Exception) { }
            connectionScope.launch {
                delay(CLEANUP_DELAY)
                try { gatt.close() } catch (_: Exception) { }
            }
        } else {
            serverManager.disconnectLink(connection.device, linkID)
        }
    }

    private fun isAdapterOn(): Boolean =
        try { bluetoothAdapter?.isEnabled == true } catch (_: Exception) { false }

    private fun registerAdapterStateReceiver() {
        if (!adapterReceiverRegistered.compareAndSet(false, true)) return
        try {
            ContextCompat.registerReceiver(
                appContext,
                adapterStateReceiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
        } catch (e: Exception) {
            adapterReceiverRegistered.set(false)
            Log.e(TAG, "Failed to register Bluetooth state receiver: ${e.message}")
        }
    }

    private fun unregisterAdapterStateReceiver() {
        if (!adapterReceiverRegistered.compareAndSet(true, false)) return
        try { appContext.unregisterReceiver(adapterStateReceiver) } catch (_: Exception) { }
    }

    private fun adapterStateName(state: Int): String = when (state) {
        BluetoothAdapter.STATE_OFF -> "OFF"
        BluetoothAdapter.STATE_TURNING_ON -> "TURNING_ON"
        BluetoothAdapter.STATE_ON -> "ON"
        BluetoothAdapter.STATE_TURNING_OFF -> "TURNING_OFF"
        else -> "UNKNOWN($state)"
    }

    /**
     * Indicates whether this instance can be safely reused for a future start.
     * Returns false if its coroutine scope has been cancelled.
     */
    fun isReusable(): Boolean {
        return connectionScope.isActive
    }
    
    /**
     * Broadcast packet to connected devices with connection limit enforcement
     * Automatically fragments large packets to fit within BLE MTU limits
     */
    fun broadcastPacket(routed: RoutedPacket): Boolean {
        if (!isActive || !isBleTransportEnabled()) {
            experimentRecorder.onBroadcastDropped(routed.packet)
            return false
        }

        return packetBroadcaster.broadcastPacket(
            routed,
            serverManager.getGattServer(),
            serverManager.getCharacteristic()
        )
    }

    suspend fun broadcastControlPacketAndAwaitAcceptance(routed: RoutedPacket): Boolean {
        if (!isActive || !isBleTransportEnabled()) return false

        return packetBroadcaster.broadcastControlPacketAndAwaitAcceptance(
            routed,
            serverManager.getGattServer(),
            serverManager.getCharacteristic()
        )
    }

    fun sendToPeer(peerID: String, routed: RoutedPacket): Boolean {
        if (!isActive || !isBleTransportEnabled()) return false
        return packetBroadcaster.sendToPeer(
            peerID,
            routed,
            serverManager.getGattServer(),
            serverManager.getCharacteristic()
        )
    }

    fun cancelTransfer(transferId: String): Boolean {
        return packetBroadcaster.cancelTransfer(transferId)
    }

    /**
     * Send a packet directly to a specific peer, without broadcasting to others.
     */
    fun sendPacketToPeer(peerID: String, packet: BitchatPacket): Boolean {
        if (!isActive || !isBleTransportEnabled()) return false
        return packetBroadcaster.sendPacketToPeer(
            RoutedPacket(packet),
            peerID,
            serverManager.getGattServer(),
            serverManager.getCharacteristic()
        )
    }

    fun sendPacketToLink(deviceAddress: String, linkID: String, packet: BitchatPacket): Boolean {
        if (!isActive || !isBleTransportEnabled()) return false
        return packetBroadcaster.sendPacketToLink(
            RoutedPacket(packet),
            deviceAddress,
            linkID,
            serverManager.getGattServer(),
            serverManager.getCharacteristic()
        )
    }
    

    // Expose role controls for debug UI
    fun startServer() {
        if (!isActive || !isBleTransportEnabled() || !radioRunning) return
        connectionScope.launch { if (isGattServerEnabled()) serverManager.start() }
    }
    fun stopServer() { connectionScope.launch { serverManager.stop() } }
    fun startClient() {
        if (!isActive || !isBleTransportEnabled() || !radioRunning) return
        connectionScope.launch { if (isGattClientEnabled()) clientManager.start() }
    }
    fun stopClient() { connectionScope.launch { clientManager.stop() } }

    // Inject nickname resolver for broadcaster logs
    fun setNicknameResolver(resolver: (String) -> String?) { packetBroadcaster.setNicknameResolver(resolver) }

    // Debug snapshots for connected devices
    fun getConnectedDeviceEntries(): List<Triple<String, Boolean, Int?>> {
        return try {
            connectionTracker.getConnectedDevices().values.map { dc ->
                val rssi = if (dc.rssi != Int.MIN_VALUE) dc.rssi else null
                Triple(dc.device.address, dc.isClient, rssi)
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    // Expose local adapter address for debug UI
    fun getLocalAdapterAddress(): String? = try { bluetoothAdapter?.address } catch (e: Exception) { null }

    fun isClientConnection(address: String): Boolean? {
        return try { connectionTracker.getConnectedDevices()[address]?.isClient } catch (e: Exception) { null }
    }

    /**
     * Public: connect/disconnect helpers for debug UI
     */
    fun connectToAddress(address: String): Boolean {
        if (!isActive || !isBleTransportEnabled() || !radioRunning) return false
        return clientManager.connectToAddress(address)
    }
    fun disconnectAddress(address: String) { connectionTracker.disconnectDevice(address) }


    // Optionally disconnect all connections (server and client)
    fun disconnectAll() {
        connectionScope.launch {
            // Stop and restart to force disconnects
            clientManager.stop()
            serverManager.stop()
            delay(200)
            if (isActive && isBleTransportEnabled() && radioRunning) {
                // Restart managers if service is active
                if (isGattServerEnabled()) serverManager.start()
                if (isGattClientEnabled()) clientManager.start()
            }
        }
    }


    /**
     * Get connected device count
     */
    fun getConnectedDeviceCount(): Int = connectionTracker.getConnectedDeviceCount()
    
    /**
     * Get debug information including power management
     */
    fun getDebugInfo(): String {
        return buildString {
            appendLine("=== Bluetooth Connection Manager ===")
            appendLine("Bluetooth MAC Address: ${bluetoothAdapter?.address}")
            appendLine("Active: $isActive")
            appendLine("Bluetooth Services Running: $radioRunning")
appendLine("Bluetooth Enabled: ${bluetoothAdapter?.isEnabled}")
            appendLine("Has Permissions: ${permissionManager.hasBluetoothPermissions()}")
            appendLine("GATT Server Active: ${serverManager.getGattServer() != null}")
            appendLine()
            appendLine(powerManager.getPowerInfo())
            appendLine()
            appendLine(connectionTracker.getDebugInfo())
        }
    }
    
}

/**
 * Delegate interface for Bluetooth connection manager callbacks
 */
interface BluetoothConnectionManagerDelegate {
    fun onPacketReceived(
        packet: BitchatPacket,
        peerID: String,
        device: BluetoothDevice?,
        ingressLinkID: String
    )
    fun onDeviceConnected(device: BluetoothDevice)
    fun onDeviceDisconnected(device: BluetoothDevice, linkID: String?, peerID: String?)
    fun onRSSIUpdated(deviceAddress: String, rssi: Int)
    fun onGattClientWriteComplete(deviceAddress: String, linkID: String, status: Int) = Unit
    fun onGattServerNotificationComplete(deviceAddress: String, linkID: String?, status: Int) = Unit
}
