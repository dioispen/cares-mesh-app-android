package com.bitchat.android

import android.app.Application
import com.bitchat.android.ui.theme.ThemePreferenceManager

/**
 * Main application class for bitchat Android
 */
class BitchatApplication : Application() {

    override fun onCreate() {
        super.onCreate()

        // Start the single process-wide power policy before transport components are constructed.
        com.bitchat.android.mesh.PowerManager.getInstance(this).start()

        // NOTE: upstream also initialises Tor (ArtiTorManager), the Nostr relay directory and
        // LocationNotes here. CARES runs mesh-only with a Firebase uplink, so those stay detached.

        // Initialize favorites persistence early
        try {
            com.bitchat.android.favorites.FavoritesPersistenceService.initialize(this)
        } catch (_: Exception) { }

        // Restore private conversations before background transports can deliver new messages.
        // AppStateStore merges any in-flight arrivals by message ID, so startup cannot replace
        // newer transport state with an older database snapshot.
        try {
            com.bitchat.android.services.AppStateStore.initializeConversationPersistence(this)
        } catch (_: Exception) { }


        // Initialize theme preference
        ThemePreferenceManager.init(this)

        // Initialize chat UI mode (matrix transcript vs bubbles)
        com.bitchat.android.ui.theme.ChatUiModeManager.init(this)

        // Initialize debug preference manager (persists debug toggles)
        try { com.bitchat.android.ui.debug.DebugPreferenceManager.init(this) } catch (_: Exception) { }


        // Initialize the Wi-Fi Aware transport controller. This must run after the debug
        // preference manager is initialised, or the stored toggle is unreadable and a user who
        // turned the transport off would silently get the default back on every cold start.
        //
        // initialize() only evaluates capability and applies the toggle; on a device without
        // Wi-Fi Aware, WifiAwareSupport reports unsupported and startIfPossible() returns without
        // touching WifiAwareManager, so emulators and BLE-only phones stay BLE-only.
        // Later starts come from MeshForegroundService.ensureMeshStarted() and MainActivity once
        // permissions and location services are in place.
        try {
            val wifiAwareEnabled = com.bitchat.android.ui.debug.DebugPreferenceManager.getWifiAwareEnabled()
            com.bitchat.android.wifiaware.WifiAwareController.initialize(this, wifiAwareEnabled)
        } catch (_: Exception) { }

        // Initialize mesh service preferences
        try { com.bitchat.android.service.MeshServicePreferences.init(this) } catch (_: Exception) { }

        // Proactively start the foreground service to keep mesh alive
        try { com.bitchat.android.service.MeshForegroundService.start(this) } catch (_: Exception) { }
    }
}
