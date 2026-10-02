package dev.matebridge.client.audio

/**
 * Output buffer size experiment switch (T-098, T-100): `--ei audio_buf_bursts N` sets the starting buffer to N output
 * bursts (1-6) for either output. Without it AudioTrack starts at [DEFAULT_BURSTS] and AAudio at
 * max([AAUDIO_DEFAULT_BURSTS], the size remembered for its path) (T-110 [OutBufMemory]).
 * The buffer grows by one burst, up to [MAX_BURSTS], on an output underrun (xrun) and, for AAudio, when the measured
 * headroom runs low ([OutBufGrowth]).
 *
 * AAudio default (T-114): 4 × 240 frames (20 ms). The T-099 probe's 2 bursts (10 ms) crackled continuously in game mode
 * on a busy scene; 4 bursts did not (user experiment, 2026-10-02).
 */
object AudioBufferConfig {
    const val EXTRA = "audio_buf_bursts"
    const val DEFAULT_BURSTS = 1
    const val AAUDIO_DEFAULT_BURSTS = 4
    const val MAX_BURSTS = 6

    /** The starting size in bursts for the raw extra ([raw] null = not given); out-of-range values are clamped. */
    fun startBursts(raw: Int?, default: Int = DEFAULT_BURSTS): Int = raw?.coerceIn(1, MAX_BURSTS) ?: default
}
