package com.bitchat.android.service

/**
 * Whether the mesh keeps running once the app leaves the screen, and if not, why (P1-6, ADR-0011).
 * Flutter reads it as `backgroundOperation` in `system_status`, named on the wire as [wireName].
 *
 * Without the foreground service the system may freeze the app as soon as it is in the background,
 * and nobody nearby hears this phone's Health Reports. In the 2026-11-18 trial one phone never
 * started it (`shouldStartForeground=false`) and its user could not tell.
 */
enum class MeshBackgroundStatus(val wireName: String) {
    /** The foreground service is running. */
    ACTIVE("active"),

    /** The user turned background operation off ([MeshServicePreferences.isBackgroundEnabled]). */
    BACKGROUND_DISABLED("backgroundDisabled"),

    /** Background operation is on, but the foreground service lacks its Bluetooth permissions. */
    PERMISSIONS_MISSING("permissionsMissing"),

    /** Everything allows it, yet the service is not in the foreground (e.g. the system refused the start). */
    NOT_RUNNING("notRunning");

    companion object {
        /** The same conditions [MeshForegroundService] checks before it starts and promotes itself. */
        fun resolve(
            serviceInForeground: Boolean,
            backgroundEnabled: Boolean,
            hasBluetoothPermissions: Boolean
        ): MeshBackgroundStatus = when {
            serviceInForeground -> ACTIVE
            !backgroundEnabled -> BACKGROUND_DISABLED
            !hasBluetoothPermissions -> PERMISSIONS_MISSING
            else -> NOT_RUNNING
        }
    }
}
