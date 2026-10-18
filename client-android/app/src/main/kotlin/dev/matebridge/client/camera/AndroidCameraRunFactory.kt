package dev.matebridge.client.camera

import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaCodecList
import dev.matebridge.client.session.MbLog
import dev.matebridge.client.session.VideoKeepalive

/**
 * Builds the real [CameraStreamer] over a [Camera2Pipeline] (T-355). Nothing is created before [start]. [displayDegrees]
 * is the display's rotation from its natural orientation in degrees (read on the camera thread, so it must be cheap and
 * safe from any thread).
 */
class AndroidCameraRunFactory(
    private val context: Context,
    private val displayDegrees: () -> Int,
) : CameraRunFactory {
    override fun start(plan: CameraPlan, ctx: CameraSessionCtx, facing: CameraFacing, onGaveUp: (CameraRun, String) -> Unit): CameraRun {
        val log = { warn: Boolean, ev: String, fields: String -> if (warn) MbLog.w(ev, fields, "camera") else MbLog.i(ev, fields, "camera") }
        return CameraStreamer(
            plan, ctx, facing, Camera2Pipeline(context, displayDegrees, log), onGaveUp,
            tune = { sock -> VideoKeepalive.forSocket(sock, "camera_keepalive", logOk = false) },
            log = log,
        ).start()
    }

    companion object {
        /** HELLO bit15 `CAMERA`: at least one camera and an H.264 encoder (decision 0040). Cheap; no camera is opened. */
        fun supported(context: Context): Boolean {
            val pm = context.packageManager
            val anyCamera = pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
            if (!anyCamera) return false
            return try {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                    info.isEncoder && info.supportedTypes.any { it.equals("video/avc", ignoreCase = true) }
                }
            } catch (_: RuntimeException) {
                false
            }
        }

        fun hasPermission(context: Context): Boolean =
            context.checkSelfPermission(android.Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    }
}
