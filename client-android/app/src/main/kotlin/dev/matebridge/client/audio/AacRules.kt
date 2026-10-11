package dev.matebridge.client.audio

import dev.matebridge.client.protocol.Capabilities

/**
 * Decision 0038 section 4: pure rules for the AAC-LC audio stream (`AUDIO_CONFIG.format = 2`).
 */
object AacRules {
    const val MIME = "audio/mp4a-latm"
    const val SAMPLE_RATE = 48_000
    const val CHANNELS = 2

    /** Frames in every AAC access unit; `AUDIO_FRAME.frame_count` is always this for AAC_LC. */
    const val FRAMES_PER_UNIT = 1024

    /** Largest accepted access unit, bytes (PROTOCOL.md 0x32). */
    const val MAX_UNIT_BYTES = 1536

    private const val OBJECT_TYPE_LC = 2
    private val SAMPLE_RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)

    /**
     * AudioSpecificConfig (2 bytes) for AAC-LC: 5 bits object type, 4 bits sampling frequency index, 4 bits channel
     * configuration, 3 zero bits (frame length 1024, no dependsOnCoreCoder, no extension). 48 kHz stereo gives
     * `0x11 0x90`. Null for a rate or channel count AAC-LC cannot describe this way.
     */
    fun audioSpecificConfig(sampleRate: Int, channels: Int): ByteArray? {
        val idx = SAMPLE_RATES.indexOf(sampleRate)
        if (idx < 0 || channels !in 1..7) return null
        val bits = (OBJECT_TYPE_LC shl 11) or (idx shl 7) or (channels shl 3)
        return byteArrayOf((bits shr 8).toByte(), bits.toByte())
    }

    /** A unit with another `frame_count`, or an empty / oversized body, is dropped (not a protocol error). */
    fun isValidUnit(frameCount: Int, dataLen: Int): Boolean =
        frameCount == FRAMES_PER_UNIT && dataLen in 1..MAX_UNIT_BYTES

    /** HELLO capability bit14: only when audio is on at all and the device has an AAC decoder. */
    fun capabilityBits(audioAllowed: Boolean, decoderAvailable: Boolean): Long =
        if (audioAllowed && decoderAvailable) Capabilities.AUDIO_AAC.toLong() else 0L

    /** AUDIO_PREFS `codec` of a remote session: AAC only if HELLO reported bit14. */
    fun hasAacCapability(helloCapabilities: Long): Boolean = helloCapabilities and Capabilities.AUDIO_AAC.toLong() != 0L
}

/** Decision 0038 section 6: a remote session's audio starts from a larger buffer (WAN jitter). */
object RemoteAudio {
    const val START_BUFFER_MS = 100

    /** The jitter-buffer safety a remote stream starts (and decays no lower than) with, given the normal start [normalMs]. */
    fun startMs(normalMs: Int): Int = maxOf(normalMs, START_BUFFER_MS)
}
