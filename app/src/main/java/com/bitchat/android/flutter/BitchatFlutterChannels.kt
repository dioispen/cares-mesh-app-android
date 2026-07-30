package com.bitchat.android.flutter

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.bluetooth.BluetoothAdapter
import android.location.LocationManager
import android.util.Log
import com.bitchat.android.identity.SecureIdentityStateManager
import com.bitchat.android.service.MeshServiceHolder
import com.bitchat.android.service.MeshForegroundService
import com.bitchat.android.crypto.EncryptionService
import com.bitchat.android.onboarding.PermissionManager
import com.bitchat.android.protocol.BroadcastContentTag
import com.bitchat.android.protocol.MessageType
import com.bitchat.android.protocol.BitchatPacket
import com.bitchat.android.net.PacketUplinkManager
import com.bitchat.android.util.toHexString
import com.google.gson.Gson
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 核心橋樑：負責 Kotlin 原生功能與 Flutter UI 的通訊
 */
class BitchatFlutterChannels(
    private val context: Context,
    messenger: BinaryMessenger,
    private val activity: Activity? = null
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL_NAME)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL_NAME)
    private val identityManager = SecureIdentityStateManager(context)
    private val permissionManager = PermissionManager(context)
    private val uplinkManager = PacketUplinkManager(context)
    private val gson = Gson()

    private var eventSink: EventChannel.EventSink? = null

    // 監聽系統藍牙與位置狀態變更
    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            emitStatusUpdate()
        }
    }

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
        }
        context.registerReceiver(statusReceiver, filter)

        // 監聽來自 Mesh 的封包，統一格式轉發給 Flutter 自行解析
        // 注意：ContentTag 已經在 MessageHandler.handleTaggedBroadcast() 那一層被去除，
        // 這裡拿到的 packet.payload 一定是「未加 tag」的原始資料，不可再嘗試偵測/剝除 tag byte
        // （payload[0] 剛好等於 0x01 是合法資料，例如 reporterId 長度恰為 1 時，會被誤判成 tag 而遭到錯誤剝除）。
        MeshServiceHolder.onPacketReceived = { packet: BitchatPacket ->
            Log.d("BitchatBridge", "📨 收到封包，類型: 0x${packet.type.toString(16).uppercase()}, 大小: ${packet.payload.size}")
            emitEvent(mapOf(
                "type"       to "packet",
                "packetType" to packet.type.toInt(),
                "senderId"   to packet.senderID.toHexString(),
                "timestamp"  to packet.timestamp.toLong(),
                "payload"    to packet.payload.map { it.toInt() and 0xFF }
            ))
        }
    }

    private fun getStatusMap(): Map<String, Any> {
        val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
        val bluetoothEnabled = bluetoothAdapter?.isEnabled ?: false
        
        val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val locationEnabled = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) || 
                             locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        
        val permissionsGranted = permissionManager.areRequiredPermissionsGranted()
        val notificationGranted = if (android.os.Build.VERSION.SDK_INT >= 33) {
            permissionManager.isPermissionGranted(android.Manifest.permission.POST_NOTIFICATIONS)
        } else true

        return mapOf(
            "type" to "system_status",
            "bluetoothEnabled" to bluetoothEnabled,
            "locationEnabled" to locationEnabled,
            "permissionsGranted" to permissionsGranted,
            "notificationGranted" to notificationGranted
        )
    }

    private fun emitStatusUpdate() {
        emitEvent(getStatusMap())
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getSystemStatus" -> {
                result.success(getStatusMap())
            }

            "checkPermissions" -> {
                val requiredGranted = permissionManager.areRequiredPermissionsGranted()
                val notificationGranted = if (android.os.Build.VERSION.SDK_INT >= 33) {
                    permissionManager.isPermissionGranted(android.Manifest.permission.POST_NOTIFICATIONS)
                } else true
                result.success(requiredGranted && notificationGranted)
            }

            "requestPermissions" -> {
                if (activity == null) {
                    result.error("NO_ACTIVITY", "Cannot request permissions without an activity", null)
                    return
                }
                val permissions = mutableListOf<String>()
                permissions.addAll(permissionManager.getRequiredPermissions())
                if (android.os.Build.VERSION.SDK_INT >= 33) {
                    permissions.add(android.Manifest.permission.POST_NOTIFICATIONS)
                }
                activity.requestPermissions(permissions.toTypedArray(), 1001)
                result.success(true)
            }

            "isRegistered" -> {
                result.success(identityManager.hasIdentityData())
            }

            "startMesh" -> {
                try {
                    MeshForegroundService.start(context)
                    val service = MeshServiceHolder.getOrCreate(context)
                    service.startServices()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("START_FAILED", e.message, null)
                }
            }

            "sendHealthReport" -> {
                Log.d("BitchatBridge", "🟢 sendHealthReport 被調用，參數類型: ${call.arguments?.javaClass?.simpleName}")
                try {
                    // 期望接收二進制數據
                    val payload = when (call.arguments) {
                        is List<*> -> {
                            // 如果 Flutter 發送的是 List<int>（二進制）
                            (call.arguments as List<*>).filterIsInstance<Int>().map { it.toByte() }.toByteArray()
                        }
                        is Map<*, *> -> {
                            // 如果仍然是 Map（JSON），則轉換為 HealthReportPayload 進行二進制編碼
                            val reportMap = call.arguments as Map<*, *>
                            val report = convertMapToHealthReportPayload(reportMap)
                            if (report != null) {
                                report.encode()
                            } else {
                                null
                            }
                        }
                        else -> null
                    }
                    
                    if (payload == null) {
                        Log.e("BitchatBridge", "❌ payload 為 null，無法編碼")
                        result.error("INVALID_FORMAT", "Unsupported payload format", null)
                        return@onMethodCall
                    }
                    Log.d("BitchatBridge", "✅ payload 編碼成功，大小: ${payload.size} 字節")
                    
                    val success = sendHealthReportPacket(payload)
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("SERVICE_NOT_READY", "Mesh service is not running", null)
                    }
                } catch (e: Exception) {
                    result.error("SEND_FAILED", e.message, null)
                }
            }

            "getNearbyPeers" -> {
                val service = MeshServiceHolder.meshService
                val peers = service?.getPeerNicknames() ?: emptyMap<String, String>()
                result.success(peers)
            }

            "sendMessage" -> {
                val text = call.argument<String>("text") ?: ""
                val service = MeshServiceHolder.meshService
                service?.sendMessage(text)
                result.success(null)
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        emitStatusUpdate()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun emitEvent(event: Map<String, Any?>) {
        activity?.runOnUiThread {
            eventSink?.success(event)
        }
    }

    /**
     * 發送 HEALTH_REPORT 類型的 BitchatPacket
     * @param payload 已編碼的二進制健康報告數據
     * @return 如果發送成功返回 true，否則返回 false
     */
    private fun sendHealthReportPacket(payload: ByteArray): Boolean {
        val service = MeshServiceHolder.meshService
        return if (service != null) {
            val publicKey = identityManager.loadStaticKey()?.second
            val senderIdHex = publicKey?.toHexString() ?: "0000000000000000"
            
            val taggedPayload = byteArrayOf(BroadcastContentTag.HEALTH_REPORT.value) + payload
            val packet = BitchatPacket(
                type = MessageType.HEALTH_REPORT.value,
                ttl = 3u,
                senderID = senderIdHex,
                payload = taggedPayload
            )
            Log.d("BitchatBridge", "🔄 正在發送 HEALTH_REPORT 封包，大小: ${payload.size}，類型: ${packet.type}, TTL: 3")
            
            // 通過 BluetoothMeshService 廣播 HEALTH_REPORT 封包
            service.sendBroadcastPacket(packet)
            uplinkManager.uplinkPacketIfNeeded(packet)
            Log.d("BitchatBridge", "📤 HEALTH_REPORT 已提交給網格服務")
            true
        } else {
            Log.e("BitchatBridge", "❌ Mesh 服務未啟動，無法發送 HEALTH_REPORT")
            false
        }
    }

    private fun convertMapToHealthReportPayload(map: Map<*, *>): com.bitchat.android.protocol.HealthReportPayload? {
        return try {
            com.bitchat.android.protocol.HealthReportPayload(
                reporterId = map["reporterId"] as? String ?: return null,
                name = map["name"] as? String ?: return null,
                phone = map["phone"] as? String ?: return null,
                bloodType = map["bloodType"] as? String,
                status = map["status"] as? String ?: return null,
                description = map["description"] as? String,
                lat = (map["lat"] as? Number)?.toDouble(),
                lng = (map["lng"] as? Number)?.toDouble(),
                reportTime = map["reportTime"] as? String ?: return null
            )
        } catch (e: Exception) {
            null
        }
    }

    fun destroy() {
        try { context.unregisterReceiver(statusReceiver) } catch (e: Exception) {}
        MeshServiceHolder.onPacketReceived = null
    }

    companion object {
        const val METHOD_CHANNEL_NAME = "com.bitchat/bridge/methods"
        const val EVENT_CHANNEL_NAME = "com.bitchat/bridge/events"
    }
}
