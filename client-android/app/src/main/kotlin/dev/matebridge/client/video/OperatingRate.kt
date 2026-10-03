package dev.matebridge.client.video

/**
 * MediaFormat.KEY_OPERATING_RATE policy (T-052): the stream fps. The `--ei oprate` switch is retired (T-183); the
 * HiSilicon decoder does not take the key (NOTES.md), but the default stays until shown to be a no-op.
 */
object OperatingRate {
    /** The value to set, or null to leave the key unset (unknown stream fps). */
    fun resolve(streamFps: Int): Int? = if (streamFps > 0) streamFps else null
}
