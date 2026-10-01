package dev.matebridge.client.audio

/**
 * AudioTrack buffer size experiment switch (T-098): `--ei audio_buf_bursts N` sets the starting buffer to N output
 * bursts (1-6, default 1). A track underrun still grows it by one burst, up to [MAX_BURSTS].
 */
object AudioBufferConfig {
    const val EXTRA = "audio_buf_bursts"
    const val DEFAULT_BURSTS = 1
    const val MAX_BURSTS = 6

    /** The starting size in bursts for the raw extra ([raw] null = not given); out-of-range values are clamped. */
    fun startBursts(raw: Int?): Int = raw?.coerceIn(1, MAX_BURSTS) ?: DEFAULT_BURSTS
}
