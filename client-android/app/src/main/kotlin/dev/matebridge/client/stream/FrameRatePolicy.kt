package dev.matebridge.client.stream

/** What to ask the platform for while streaming at a given stream fps. Pure Kotlin. */
object FrameRatePolicy {
    /** Launch extra `hz`: follow the stream fps (default). 0 = leave the display mode alone, N = fixed target. */
    const val HZ_FOLLOW_STREAM = -1

    /** Target for preferredDisplayModeId; 0 means "do not touch the mode". */
    fun modeTargetHz(hzExtra: Int, streamFps: Int): Int =
        if (hzExtra == HZ_FOLLOW_STREAM) streamFps.coerceAtLeast(0) else hzExtra.coerceAtLeast(0)

    /** Rate for Surface.setFrameRate; 0 means "do not call". [frateExtra]: -1 unset, 0 off, N explicit (T-018). */
    fun surfaceRate(frateExtra: Int, streamFps: Int): Int = when {
        frateExtra == 0 -> 0
        frateExtra > 0 -> frateExtra
        else -> streamFps.coerceAtLeast(0)
    }
}
