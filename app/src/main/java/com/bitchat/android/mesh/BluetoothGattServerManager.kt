package com.bitchat.android.mesh

import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.util.AppConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.*
import java.util.concurrent.ConcurrentHashMap

/**
 * Manages GATT server operations, advertising, and server-side connections
 */
class BluetoothGattServerManager(
    private val context: Context,
    private val connectionScope: CoroutineScope,
    private val connectionTracker: BluetoothConnectionTracker,
    private val permissionManager: BluetoothPermissionManager,
    private val powerManager: PowerManager,
    private val delegate: BluetoothConnectionManagerDelegate?,
    private val myPeerID: String
) {
    
    companion object {
        private const val TAG = "BluetoothGattServerManager"
        // Self-healing advertising recovery tuning
        private const val ADVERTISE_RETRY_BASE_MS = 3_000L      // base backoff for transient advertise failures
        private const val ADVERTISE_MAX_RETRY_DELAY_MS = 30_000L // cap on backoff delay
    }
    
    // Core Bluetooth components
    private val bluetoothManager: BluetoothManager = 
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    // 每次 start() 重新取得：藍牙關閉時拿到的是 null，重新開啟後舊的 advertiser 也可能已失效（P0-1）。
    @Volatile private var bleAdvertiser: BluetoothLeAdvertiser? = null
    
    // GATT server for peripheral mode
    private var gattServer: BluetoothGattServer? = null
    private val serverLinkIDs = ConcurrentHashMap<String, String>()
    private var characteristic: BluetoothGattCharacteristic? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var advertiseRetryCount = 0
    
    // State management
    private var isActive = false

    private fun isBleTransportEnabled(): Boolean {
        return try {
            com.bitchat.android.ui.debug.DebugSettingsManager.getInstance().bleEnabled.value
        } catch (_: Exception) {
            try { com.bitchat.android.ui.debug.DebugPreferenceManager.getBleEnabled(true) } catch (_: Exception) { true }
        }
    }

    private fun isServerRoleEnabled(): Boolean {
        return isBleTransportEnabled() &&
            (try { com.bitchat.android.ui.debug.DebugSettingsManager.getInstance().gattServerEnabled.value } catch (_: Exception) { true })
    }

    /**
     * Disconnect a specific device (used by ConnectionManager to enforce overall limits)
     */
    fun disconnectDevice(device: BluetoothDevice) {
        try {
            gattServer?.cancelConnection(device)
        } catch (e: Exception) {
            Log.w(TAG, "Error disconnecting device ${device.address}: ${e.message}")
        }
    }

    /**
     * 本機已從連線表拆掉 [linkID] 這條 server 端鏈路，不等堆疊的斷線回呼。先忘掉它的 linkID，
     * 之後這個位址晚到的寫入會被當成舊連線丟棄，再請堆疊斷線。
     */
    fun disconnectLink(device: BluetoothDevice, linkID: String) {
        serverLinkIDs.remove(device.address, linkID)
        disconnectDevice(device)
    }
    
    /**
     * Start GATT server
     */
    fun start(): Boolean {
        // Respect debug setting
        if (!isServerRoleEnabled()) {
            Log.i(TAG, "Server start skipped: BLE/GATT Server disabled in debug settings")
            return false
        }

        if (isActive) {
            return true
        }
        if (!permissionManager.hasBluetoothPermissions()) {
            Log.e(TAG, "Missing Bluetooth permissions")
            return false
        }
        
        if (bluetoothAdapter?.isEnabled != true) {
            Log.e(TAG, "Bluetooth is not enabled")
            return false
        }
        
        val advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(TAG, "BLE advertiser not available")
            return false
        }
        bleAdvertiser = advertiser
        
        isActive = true
        
        connectionScope.launch {
            setupGattServer()
            delay(300) // Brief delay to ensure GATT server is ready
            startAdvertising()
        }
        
        return true
    }
    
    /**
     * Stop GATT server
     */
    fun stop() {
        if (!isActive) {
            // Idempotent stop
            stopAdvertising()
            // Ensure server is closed if present
            gattServer?.close()
            gattServer = null
            serverLinkIDs.clear()
            return
        }

        isActive = false

        // 呼叫端都在 connectionScope 的 coroutine 裡。同步做完，藍牙重建時接著呼叫的 start() 建立的
        // 新 GATT server 才不會被晚一步執行的 close() 關掉。
        stopAdvertising()
        
        // Try to cancel any active connections explicitly before closing
        try {
            // Disconnect ALL server connections
            val servers = connectionTracker.getConnectedDevices().values.filter { !it.isClient }
            servers.forEach { d ->
                try { gattServer?.cancelConnection(d.device) } catch (_: Exception) { }
            }
        } catch (_: Exception) { }
        
        // Close GATT server
        try { gattServer?.close() } catch (e: Exception) {
            Log.w(TAG, "Error closing GATT server: ${e.message}")
        }
        gattServer = null
        serverLinkIDs.clear()
        
        Log.i(TAG, "GATT server stopped")
    }
    
    /**
     * Get GATT server instance
     */
    fun getGattServer(): BluetoothGattServer? = gattServer
    
    /**
     * Get characteristic instance
     */
    fun getCharacteristic(): BluetoothGattCharacteristic? = characteristic
    
    /**
     * Setup GATT server with proper sequencing
     */
    @Suppress("DEPRECATION")
    private fun setupGattServer() {
        if (!permissionManager.hasBluetoothPermissions()) return
        
        val serverCallback = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                // Guard against callbacks after service shutdown
                if (!isActive) {
                    return
                }

                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        Log.i(TAG, "Connected to ${device.address} (server)")
                        val linkID = UUID.randomUUID().toString()
                        serverLinkIDs[device.address] = linkID
                        
                        // Get best available RSSI (scan RSSI for server connections)
                        val rssi = connectionTracker.getBestRSSI(device.address) ?: Int.MIN_VALUE
                        
                        val deviceConn = BluetoothConnectionTracker.DeviceConnection(
                            device = device,
                            rssi = rssi,
                            isClient = false,
                            linkID = linkID
                        )
                        connectionTracker.addDeviceConnection(device.address, deviceConn)

                        connectionScope.launch {
                            delay(1000)
                            if (isActive) { // Check if still active
                                delegate?.onDeviceConnected(device)
                            }
                        }
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        Log.i(TAG, "Disconnected from ${device.address} (server)")
                        val linkID = serverLinkIDs.remove(device.address)
                        // 只取這一條鏈路自己確認過的 peer。linkID 為 null 表示本機已先拆掉這條鏈路、
                        // 通知過上層（disconnectLink），這裡不再報一次 peer。
                        val disconnectedPeerID = linkID?.let {
                            connectionTracker.removeConnectionIfCurrent(device.address, it)?.observedPeerID
                        }
                        // Notify delegate about device disconnection so higher layers can update direct flags
                        delegate?.onDeviceDisconnected(device, linkID, disconnectedPeerID)
                    }
                }
            }
            
            override fun onServiceAdded(status: Int, service: BluetoothGattService) {
                // Guard against callbacks after service shutdown
                if (!isActive) {
                    return
                }

                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.e(TAG, "Server: Failed to add service: ${service.uuid}, status: $status")
                }
            }
            
            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray
            ) {
                // Guard against callbacks after service shutdown
                if (!isActive) {
                    return
                }

                if (characteristic.uuid == AppConstants.Mesh.Gatt.CHARACTERISTIC_UUID) {
                    val linkID = serverLinkIDs[device.address]
                    if (linkID == null) {
                        Log.d(TAG, "Server: Dropping packet from stale connection ${device.address}")
                        if (responseNeeded) {
                            gattServer?.sendResponse(
                                device,
                                requestId,
                                BluetoothGatt.GATT_FAILURE,
                                0,
                                null
                            )
                        }
                        return
                    }
                    val packet = BitchatPacket.fromBinaryData(value)
                    if (packet != null) {
                        val peerID = packet.senderID.take(8).toByteArray().joinToString("") { "%02x".format(it) }
                        delegate?.onPacketReceived(packet, peerID, device, linkID)
                    } else {
                        Log.d(TAG, "Server: Failed to parse packet from ${device.address}, size: ${value.size} bytes")
                    }
                    
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                    }
                }
            }
            
            override fun onDescriptorWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                descriptor: BluetoothGattDescriptor,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray
            ) {
                // Guard against callbacks after service shutdown
                if (!isActive) {
                    return
                }

                if (BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE.contentEquals(value)) {
                    connectionTracker.addSubscribedDevice(device)

                    connectionScope.launch {
                        delay(100)
                        if (isActive) { // Check if still active
                            delegate?.onDeviceConnected(device)
                        }
                    }
                }
                
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            }

            override fun onNotificationSent(device: BluetoothDevice, status: Int) {
                delegate?.onGattServerNotificationComplete(
                    device.address,
                    serverLinkIDs[device.address],
                    status
                )
            }
        }
        
        // Proper cleanup sequencing to prevent race conditions
        gattServer?.let { server ->
            try {
                server.close()
            } catch (e: Exception) {
                Log.w(TAG, "Error closing existing GATT server: ${e.message}")
            }
        }

        // Small delay to ensure cleanup is complete
        Thread.sleep(100)

        if (!isActive) {
            return
        }
        
        // Create new server
        gattServer = bluetoothManager.openGattServer(context, serverCallback)
        
        // Create characteristic with notification support
        characteristic = BluetoothGattCharacteristic(
            AppConstants.Mesh.Gatt.CHARACTERISTIC_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or 
            BluetoothGattCharacteristic.PROPERTY_WRITE or 
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ or 
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        
        val descriptor = BluetoothGattDescriptor(
            AppConstants.Mesh.Gatt.DESCRIPTOR_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        characteristic?.addDescriptor(descriptor)
        
        val service = BluetoothGattService(AppConstants.Mesh.Gatt.SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(characteristic)
        
        gattServer?.addService(service)
        
        Log.i(TAG, "GATT server setup complete")
    }
    
    /**
     * Start advertising
     */
    @Suppress("DEPRECATION")
    private fun startAdvertising() {
        // Respect debug setting
        val enabled = isServerRoleEnabled()

        // Guard conditions – never throw here to avoid crashing the app from a background coroutine
        if (!permissionManager.hasBluetoothPermissions()) {
            Log.w(TAG, "Not starting advertising: missing Bluetooth permissions")
            return
        }
        if (bluetoothAdapter == null) {
            Log.w(TAG, "Not starting advertising: bluetoothAdapter is null")
            return
        }
        if (!isActive) {
            return
        }
        if (!enabled) {
            Log.d(TAG, "Not starting advertising: GATT Server disabled via debug settings")
            return
        }
        val advertiser = bleAdvertiser
        if (advertiser == null) {
            Log.w(TAG, "Not starting advertising: BLE advertiser not available on this device")
            return
        }
        if (!bluetoothAdapter.isMultipleAdvertisementSupported) {
            Log.w(TAG, "Not starting advertising: multiple advertisement not supported on this device")
            return
        }

        val settings = powerManager.getAdvertiseSettings()
        
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(AppConstants.Mesh.Gatt.SERVICE_UUID))
            .setIncludeTxPowerLevel(false)
            .setIncludeDeviceName(false)
            .build()
            
        // Add stable identity (first 8 bytes of peerID) to Scan Response
        // This allows scanners to deduplicate devices even if MAC address rotates
        val peerIDBytes = try {
            myPeerID.chunked(2).map { it.toInt(16).toByte() }.toByteArray().take(8).toByteArray()
        } catch (e: Exception) {
            ByteArray(0)
        }
        
        val scanResponse = AdvertiseData.Builder()
            .addServiceData(ParcelUuid(AppConstants.Mesh.Gatt.SERVICE_UUID), peerIDBytes)
            .setIncludeTxPowerLevel(false)
            .setIncludeDeviceName(false)
            .build()
        
        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                advertiseRetryCount = 0
                val mode = try {
                    powerManager.getPowerInfo().split("Current Mode: ")[1].split("\n")[0]
                } catch (_: Exception) { "unknown" }
                Log.i(TAG, "Advertising started (power mode: $mode)")
            }

            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "Advertising failed: $errorCode")
                // Previously this only logged, so if advertising failed this device became
                // undiscoverable until a manual BLE toggle. Retry transient failures with backoff.
                when (errorCode) {
                    ADVERTISE_FAILED_ALREADY_STARTED -> Unit // already advertising, no retry
                    ADVERTISE_FAILED_DATA_TOO_LARGE -> Unit // config issue, not retrying
                    ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> Unit // unsupported, not retrying
                    ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> {
                        scheduleAdvertiseRestart("too-many-advertisers")
                    }
                    ADVERTISE_FAILED_INTERNAL_ERROR -> {
                        scheduleAdvertiseRestart("internal-error")
                    }
                    else -> {
                        scheduleAdvertiseRestart("unknown-$errorCode")
                    }
                }
            }
        }
        
        try {
            advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback)
        } catch (se: SecurityException) {
            Log.e(TAG, "SecurityException starting advertising (missing permission?): ${se.message}")
        } catch (e: Exception) {
            Log.e(TAG, "Exception starting advertising: ${e.message}")
        }
    }
    
    /**
     * Stop advertising
     */
    @Suppress("DEPRECATION")
    private fun stopAdvertising() {
        val advertiser = bleAdvertiser
        if (!permissionManager.hasBluetoothPermissions() || advertiser == null) return
        try {
            advertiseCallback?.let { cb -> advertiser.stopAdvertising(cb) }
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping advertising: ${e.message}")
        }
    }
    
    /**
     * Schedule an advertising restart with incremental backoff after a transient failure.
     */
    private fun scheduleAdvertiseRestart(reason: String) {
        advertiseRetryCount++
        val delayMs = (ADVERTISE_RETRY_BASE_MS * advertiseRetryCount).coerceAtMost(ADVERTISE_MAX_RETRY_DELAY_MS)
        Log.w(TAG, "Scheduling advertising restart in ${delayMs}ms (attempt $advertiseRetryCount, reason=$reason)")
        connectionScope.launch {
            delay(delayMs)
            if (isActive && isServerRoleEnabled()) {
                stopAdvertising()
                delay(100)
                startAdvertising()
            }
        }
    }

    /**
     * Restart advertising (for power mode changes)
     */
    fun restartAdvertising() {
        // Respect debug setting
        val enabled = isServerRoleEnabled()
        if (!isActive || !enabled) {
            stopAdvertising()
            return
        }

        connectionScope.launch {
            stopAdvertising()
            delay(100)
            startAdvertising()
        }
    }
}
