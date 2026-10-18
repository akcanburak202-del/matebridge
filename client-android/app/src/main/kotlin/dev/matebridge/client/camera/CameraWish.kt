package dev.matebridge.client.camera

import dev.matebridge.client.protocol.CameraPrefs

/** "Kamera" setting (T-355, decision 0040): Kapalı (default) or Otomatik (the Mac starts it when an app uses the virtual camera). */
enum class CameraMode(val id: String, val wire: Int, val label: String) {
    OFF("off", CameraPrefs.MODE_OFF, "Kapalı"),
    AUTO("auto", CameraPrefs.MODE_AUTO, "Otomatik");

    companion object {
        /** Default (also for an unknown stored value): [OFF]. */
        fun parse(id: String?): CameraMode = entries.firstOrNull { it.id == id } ?: OFF
    }
}

/** "Kamera yönü" setting: Ön (default) or Arka. */
enum class CameraFacing(val id: String, val wire: Int, val label: String) {
    FRONT("front", CameraPrefs.FACING_FRONT, "Ön"),
    BACK("back", CameraPrefs.FACING_BACK, "Arka");

    companion object {
        /** Default (also for an unknown stored value): [FRONT]. */
        fun parse(id: String?): CameraFacing = entries.firstOrNull { it.id == id } ?: FRONT
    }
}

/** What the user asked for, before the permission and session rules ([CameraPrefsPolicy]). */
data class CameraWish(val mode: CameraMode = CameraMode.OFF, val facing: CameraFacing = CameraFacing.FRONT)

/** The `CAMERA_PREFS` this client sends (PROTOCOL.md 0x0E). Pure. */
object CameraPrefsPolicy {
    /**
     * AUTO only when the user wants it AND the runtime permission is held AND the session is not remote (decision 0038:
     * the remote profile never uses the camera). Anything else is OFF; the facing is always the user's choice.
     */
    fun wire(wish: CameraWish, permissionGranted: Boolean, remote: Boolean, releaseSeq: Int = 0): CameraPrefs {
        val auto = wish.mode == CameraMode.AUTO && permissionGranted && !remote
        return CameraPrefs(if (auto) CameraPrefs.MODE_AUTO else CameraPrefs.MODE_OFF, wish.facing.wire, releaseSeq)
    }
}

/**
 * The "Kamerayı şimdi kapat" counter (T-357, decision 0040 addendum 2). It only grows (u16, wraps) for the whole app run:
 * the host takes the first value of a session as its baseline, so it never has to restart at 0. Thread-safe.
 */
class CameraReleaseCounter {
    @Volatile var value: Int = 0
        private set

    /** One more tap; returns the new value. */
    @Synchronized fun bump(): Int { value = (value + 1) and 0xFFFF; return value }
}

/** What the camera is doing right now, for the status line under the settings. */
enum class CameraUiState { IDLE, ACTIVE, UNAVAILABLE }

/** The status line texts of the "Kamera" section (T-355). Pure. */
object CameraStatusText {
    const val OFF = "Kamera kapalı"
    const val NO_USE = "Mac kamerayı kullanmıyor"
    const val ACTIVE = "Kamera açık"
    const val UNAVAILABLE = "Mac'te OBS sanal kamera yok"
    const val NO_PERMISSION = "Kamera izni yok"

    /**
     * [permissionDenied]: the user refused the prompt (cleared when they pick Otomatik again). A stored Otomatik without
     * the permission (revoked later) says the same. [state] only matters while the mode is Otomatik.
     */
    fun text(mode: CameraMode, permissionGranted: Boolean, permissionDenied: Boolean, state: CameraUiState): String = when {
        mode == CameraMode.AUTO && !permissionGranted -> NO_PERMISSION
        mode == CameraMode.OFF && permissionDenied && !permissionGranted -> NO_PERMISSION
        mode == CameraMode.OFF -> OFF
        state == CameraUiState.ACTIVE -> ACTIVE
        state == CameraUiState.UNAVAILABLE -> UNAVAILABLE
        else -> NO_USE
    }
}
