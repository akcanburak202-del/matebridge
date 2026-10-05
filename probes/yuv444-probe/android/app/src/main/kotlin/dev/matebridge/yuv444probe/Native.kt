package dev.matebridge.yuv444probe

import android.hardware.HardwareBuffer
import android.view.Surface

/** JNI surface of `libY444native` (src/main/cpp). Each GL context (raw, present) must be used from one thread. */
object Native {
    init {
        System.loadLibrary("y444native")
    }

    /** `key=value` lines: GL / EGL extension flags and lists, Vulkan devices, YCbCr feature and extension flags. */
    @JvmStatic external fun caps(): String

    /** Empty on success, else the failure text. */
    @JvmStatic external fun rawInit(): String
    @JvmStatic external fun rawShutdown()

    /** Raw Y/Cb/Cr of [hwb] through GL_EXT_YUV_target vs tightly packed CPU planes; one result line. */
    @JvmStatic external fun rawCompare(hwb: HardwareBuffer, w: Int, h: Int, y: ByteArray, u: ByteArray, v: ByteArray): String

    /** Empty on success, else the failure text. [mode] is [GlMode.native]. */
    @JvmStatic external fun presentInit(surface: Surface, w: Int, h: Int, mode: Int, swapInterval: Int): String
    @JvmStatic external fun presentFeatures(): String

    /** 0 on success. [auxHwb] may be null (the merge pass then samples main twice). */
    @JvmStatic external fun presentDraw(mainHwb: HardwareBuffer, auxHwb: HardwareBuffer?, queuedNs: Long): Int
    @JvmStatic external fun presentLastError(): String
    @JvmStatic external fun presentDrainTimestamps(): LongArray
    @JvmStatic external fun presentDrainGpuNs(): LongArray
    @JvmStatic external fun presentShutdown()
}
