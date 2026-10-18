package dev.matebridge.client.camera

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager

/** Camera2 side of [CameraTargets] (T-358): reads `CameraCharacteristics` only, never opens a camera. */
object AndroidCameraTargets {
    @Volatile private var wideCached: Boolean? = null

    fun infos(mgr: CameraManager): List<CamInfo> = mgr.cameraIdList.mapNotNull { id ->
        try {
            val ch = mgr.getCameraCharacteristics(id)
            val physical = ch.physicalCameraIds.associateWith { pid ->
                try { focal(mgr.getCameraCharacteristics(pid)) } catch (_: RuntimeException) { null }
            }
            CamInfo(id, ch.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK, focal(ch), physical)
        } catch (_: Exception) {
            null // one broken camera must not hide the others
        }
    }

    private fun focal(ch: CameraCharacteristics): Float? = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.minOrNull()

    fun resolve(mgr: CameraManager, facing: CameraFacing): CameraTarget? = CameraTargets.resolve(infos(mgr), facing)

    /** Is there a rear wide-angle camera? Decided once from the characteristics, then cached. */
    fun wideSupported(mgr: CameraManager, log: (String) -> Unit = {}): Boolean {
        wideCached?.let { return it }
        val t = try { CameraTargets.wide(infos(mgr)) } catch (_: Exception) { null }
        log(if (t == null) "wide=unsupported" else "wide=supported path=${if (t.physicalId != null) "b_physical" else "a_direct"} open=${t.openId} char=${t.charId}")
        wideCached = t != null
        return t != null
    }
}
