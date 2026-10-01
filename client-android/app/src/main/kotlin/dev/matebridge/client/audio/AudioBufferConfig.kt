package dev.matebridge.client.audio

/**
 * Output buffer size experiment switch (T-098, T-100): `--ei audio_buf_bursts N` sets the starting buffer to N output
 * bursts (1-6) for either output. Without it AudioTrack starts at [DEFAULT_BURSTS] and AAudio at
 * [AAUDIO_DEFAULT_BURSTS] (T-099 probe: 2 × 240 frames, 0 xruns). An output underrun (xrun) still grows it by one
 * burst, up to [MAX_BURSTS].
 */
object AudioBufferConfig {
    const val EXTRA = "audio_buf_bursts"
    const val DEFAULT_BURSTS = 1
    const val AAUDIO_DEFAULT_BURSTS = 2
    const val MAX_BURSTS = 6

    /** The starting size in bursts for the raw extra ([raw] null = not given); out-of-range values are clamped. */
    fun startBursts(raw: Int?, default: Int = DEFAULT_BURSTS): Int = raw?.coerceIn(1, MAX_BURSTS) ?: default
}
