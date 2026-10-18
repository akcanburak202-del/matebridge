package dev.matebridge.client.camera

/** What the planner needs to know of one camera in `getCameraIdList()` (T-358). Pure data, filled from `CameraCharacteristics`. */
data class CamInfo(
    val id: String,
    val back: Boolean,
    /** Shortest focal length in mm (`LENS_INFO_AVAILABLE_FOCAL_LENGTHS`), null when unknown. */
    val focalMm: Float?,
    /** Physical ids of a logical multi-camera with their shortest focal length; empty for a plain camera. */
    val physical: Map<String, Float?> = emptyMap(),
)

/**
 * A camera to open: [openId] is passed to `openCamera`, [physicalId] (path b) to `OutputConfiguration.setPhysicalCameraId`,
 * and [charId] is the id whose `CameraCharacteristics` give sizes, fps and sensor orientation.
 */
data class CameraTarget(val openId: String, val physicalId: String?, val charId: String)

/** Picks the camera for a facing (T-358). Pure; the Camera2 glue only fills [CamInfo]. */
object CameraTargets {
    /** The first camera facing the wanted way (the old T-355 rule); null if none. */
    fun plain(cams: List<CamInfo>, front: Boolean): CameraTarget? =
        cams.firstOrNull { it.back != front }?.let { CameraTarget(it.id, null, it.id) }

    /**
     * The rear wide-angle camera, or null when the device has none:
     *  a) a separate back camera in the id list with a clearly shorter focal length than the other back camera(s):
     *     open it directly;
     *  b) else a back logical multi-camera whose physical cameras differ in focal length: open the logical one and
     *     stream the shortest-focal physical id.
     */
    fun wide(cams: List<CamInfo>): CameraTarget? {
        val backs = cams.filter { it.back }
        val plainBacks = backs.filter { it.focalMm != null && it.physical.isEmpty() }
        if (plainBacks.size >= 2) {
            val sorted = plainBacks.sortedBy { it.focalMm }
            if (sorted[0].focalMm!! < sorted[1].focalMm!!) return CameraTarget(sorted[0].id, null, sorted[0].id)
        }
        for (logical in backs.filter { it.physical.size >= 2 }) {
            val known = logical.physical.entries.filter { it.value != null }.sortedBy { it.value }
            if (known.size >= 2 && known[0].value!! < known.last().value!!) {
                return CameraTarget(logical.id, known[0].key, known[0].key)
            }
        }
        return null
    }

    fun resolve(cams: List<CamInfo>, facing: CameraFacing): CameraTarget? = when (facing) {
        CameraFacing.FRONT -> plain(cams, front = true)
        CameraFacing.BACK -> plain(cams, front = false)
        CameraFacing.BACK_WIDE -> wide(cams)
    }
}
