package com.bitchat.android.flutter

import android.os.Bundle
import androidx.activity.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.bitchat.android.mesh.BluetoothMeshService
import com.bitchat.android.mesh.MeshService
import com.bitchat.android.service.MeshServiceHolder
import com.bitchat.android.ui.ChatViewModel
import com.bitchat.android.wifiaware.WifiAwareController
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.launch

/**
 * 用來啟動 Flutter UI 的 Activity（App 進入點）。
 *
 * 以 headless 方式承載上游聊天核心 [ChatViewModel]（#49），建立方式與 `MainActivity` 相同：
 * 同一個 factory、mesh service 同樣取自 [MeshServiceHolder]。前景（resumed）時把 mesh delegate
 * 掛成 [ChatViewModel]，暫停時卸下（[ForegroundMeshDelegate]），讓背景時由 `BluetoothMeshService`
 * 自己發私訊通知、不送已讀回條——上游聊天的「App 在前景」就是這個 delegate 有沒有掛上。
 *
 * 這裡只「掛」delegate，不啟動 mesh、不要求權限：mesh 由 Flutter 呼叫 `startMesh`
 * （或 `MeshForegroundService`）啟動，權限由 Flutter 的 setup 流程經 `requestPermissions` 要求。
 * mesh 尚未啟動時掛上 delegate 只是不會收到回呼，沒有副作用。
 */
class FlutterChatActivity : FlutterFragmentActivity() {

    // Same source as MainActivity: the process-wide holder shared with MeshForegroundService.
    private lateinit var meshService: BluetoothMeshService
    private lateinit var unifiedMeshService: MeshService

    private val chatViewModel: ChatViewModel by viewModels {
        object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                @Suppress("UNCHECKED_CAST")
                return ChatViewModel(application, meshService, unifiedMeshService) as T
            }
        }
    }

    private var channels: BitchatFlutterChannels? = null
    private var chatBridge: ChatBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Resolve the mesh instances before super.onCreate(): when the Activity is recreated,
        // FragmentActivity restores the FlutterFragment inside super.onCreate(), and that calls
        // configureFlutterEngine(), which needs chatViewModel. getOrCreate only constructs the
        // services; it never starts the mesh.
        meshService = MeshServiceHolder.getOrCreate(applicationContext)
        unifiedMeshService = MeshServiceHolder.getUnifiedOrCreate(applicationContext)
        super.onCreate(savedInstanceState)

        // Foreground: the ChatViewModel is the mesh delegate while resumed (mirrors MainActivity's
        // onResume/onPause); paused, the foreground service owns DM notifications.
        val foreground = ForegroundMeshDelegate(unifiedMeshService) { chatViewModel }
        lifecycle.addObserver(foreground)

        // Keep the unified mesh delegate attached when Wi-Fi Aware starts after the UI.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                WifiAwareController.running.collect { running ->
                    if (running) foreground.reattach()
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // One emitter per engine, shared by both bridges; BitchatFlutterChannels registers the
        // only method/stream handlers and hands chat methods on to ChatBridge.
        val events = BridgeEventEmitter()
        val chat = ChatBridge(chatViewModel, events)
        chatBridge = chat
        // 傳遞 activity (this) 給 channels，以便支援權限請求
        channels = BitchatFlutterChannels(
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            activity = this,
            events = events,
            additionalMethodHandlers = listOf(chat)
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channels?.destroy()
        channels = null
        chatBridge?.destroy()
        chatBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
