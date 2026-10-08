package dev.matebridge.client.video

/**
 * MediaFormat.KEY_OPERATING_RATE policy (T-052): the stream fps ([resolve]). Since T-222 the app default is [MAX];
 * the stream fps stays as the one-shot fallback format (T-217 retry in `VideoRenderer`).
 */
object OperatingRate {
    /** The value to set, or null to leave the key unset (unknown stream fps). */
    fun resolve(streamFps: Int): Int? = if (streamFps > 0) streamFps else null

    /**
     * The default since T-222 (T-217 A/B): what Moonlight sets for its allowlist (`Short.MAX_VALUE`).
     * On the HiSilicon HEVC decoder it removes the low-clock decode latency at 60 fps (NOTES.md 2026-10-04).
     */
    const val MAX = Short.MAX_VALUE.toInt()
}
