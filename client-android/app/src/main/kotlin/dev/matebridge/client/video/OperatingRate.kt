package dev.matebridge.client.video

/**
 * MediaFormat.KEY_OPERATING_RATE policy (T-052). Launch extra `--ei oprate N`:
 * [STREAM_FPS] (0, default) = the stream fps, [MAX] (-1) = Short.MAX_VALUE ("as fast as possible"),
 * [OFF] (-2) = do not set the key, N > 0 = explicit rate.
 */
object OperatingRate {
    const val STREAM_FPS = 0
    const val MAX = -1
    const val OFF = -2

    /** The value to set, or null to leave the key unset. */
    fun resolve(policy: Int, streamFps: Int): Int? = when {
        policy == OFF -> null
        policy == MAX -> Short.MAX_VALUE.toInt()
        policy > 0 -> policy
        streamFps > 0 -> streamFps
        else -> null
    }
}
