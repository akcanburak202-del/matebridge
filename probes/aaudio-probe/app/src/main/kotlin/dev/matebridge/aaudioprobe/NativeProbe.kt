package dev.matebridge.aaudioprobe

/** JNI bridge to aaprobe.cpp. */
object NativeProbe {
    init {
        System.loadLibrary("aaprobe")
    }

    /** Clears the stop flag; call once before a run sequence (never from inside a run). */
    external fun resetStop()

    /** Makes a running [runAaudio] return within one write (≤ 1 s). Safe from any thread. */
    external fun requestStop()

    /** Blocking: opens, plays for [durationMs], closes. Layout: see [NativeResult]. */
    external fun runAaudio(sharing: Int, durationMs: Int, amplitude: Float): LongArray
}
