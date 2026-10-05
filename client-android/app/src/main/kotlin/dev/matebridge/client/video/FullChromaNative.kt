package dev.matebridge.client.video

import android.hardware.HardwareBuffer
import android.view.Surface

/**
 * JNI bridge to `cpp/mbfullchroma.cpp` (decision 0034). Two independent GL contexts: the capability self-test ("raw*")
 * and the presentation ("present*"); each must be used from ONE thread. Never call anything unless [available].
 */
object FullChromaNative {
    /** False when `libmbfullchroma.so` could not be loaded (then packed full colour is never offered). */
    val available: Boolean = try {
        System.loadLibrary("mbfullchroma")
        true
    } catch (_: Throwable) {
        false
    }

    /** Empty on success, else the failure text (no GL_EXT_YUV_target, EGL failure, shader error...). */
    @JvmStatic external fun rawInit(): String
    @JvmStatic external fun rawShutdown()

    /** Raw Y/Cb/Cr of [hwb] through GL_EXT_YUV_target vs tightly packed CPU planes; one `key=value` line (`exact=1` = bit-exact). */
    @JvmStatic external fun rawCompare(hwb: HardwareBuffer, w: Int, h: Int, y: ByteArray, u: ByteArray, v: ByteArray): String

    /** Empty on success, else the failure text. */
    @JvmStatic external fun presentInit(surface: Surface, w: Int, h: Int, swapInterval: Int): String

    /** [YuvConversion.toArray]. */
    @JvmStatic external fun presentSetConversion(conv: FloatArray)
    @JvmStatic external fun presentFeatures(): String

    /**
     * 0 on success. [auxHwb] null = main-only pass. [presentNs] > 0 sets `eglPresentationTimeANDROID` (monotonic ns) for
     * this swap. [tag] comes back in [presentDrainTimestamps].
     */
    @JvmStatic external fun presentDraw(mainHwb: HardwareBuffer, auxHwb: HardwareBuffer?, tag: Long, presentNs: Long): Int

    /** Swapped frames whose compositor latch time is not known yet; -1 when frame timestamps are unavailable. */
    @JvmStatic external fun presentOutstanding(): Int
    @JvmStatic external fun presentLastError(): String

    /** Quads `[tag, latchNs, presentNs, renderCompleteNs]` of frames resolved since the last call (monotonic ns). */
    @JvmStatic external fun presentDrainTimestamps(): LongArray
    @JvmStatic external fun presentDrainGpuNs(): LongArray
    @JvmStatic external fun presentShutdown()
}
