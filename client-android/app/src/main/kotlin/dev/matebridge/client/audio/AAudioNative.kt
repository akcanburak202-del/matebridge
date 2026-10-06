package dev.matebridge.client.audio

/**
 * JNI bridge to `cpp/mbaudio.cpp` (decision 0012). A handle is one AAudio output stream (48 kHz s16 stereo,
 * LOW_LATENCY) owned by a single thread; see [AAudioSink]. Never touch it unless [available].
 */
object AAudioNative {
    /** False when `libmbaudio.so` could not be loaded (then only AudioTrack is used). */
    val available: Boolean = try {
        System.loadLibrary("mbaudio")
        true
    } catch (_: Throwable) {
        false
    }

    // AAudio constants (aaudio/AAudio.h).
    const val SHARING_EXCLUSIVE = 0
    const val SHARING_SHARED = 1
    const val OK = 0
    const val ERROR_DISCONNECTED = -899
    const val ERROR_TIMEOUT = -885
    const val ERROR_NULL = -886
    const val PERF_LOW_LATENCY = 12

    // aaudio_stream_state_t (T-287, [pause] results).
    const val STATE_PAUSING = 5
    const val STATE_PAUSED = 6
    const val STATE_STOPPING = 9
    const val STATE_STOPPED = 10
    const val STATE_DISCONNECTED = 13

    /** Short name of an AAudio stream state for logs. */
    fun stateName(state: Int): String = when (state) {
        STATE_PAUSING -> "pausing"
        STATE_PAUSED -> "paused"
        STATE_STOPPING -> "stopping"
        STATE_STOPPED -> "stopped"
        STATE_DISCONNECTED -> "disconnected"
        4 -> "started"
        3 -> "starting"
        else -> "state$state"
    }

    // Layout of open()'s info array; must match the Info enum in mbaudio.cpp.
    const val I_ERROR = 0
    const val I_STAGE = 1
    const val I_SHARING = 2
    const val I_MMAP = 3
    const val I_BURST = 4
    const val I_CAPACITY = 5
    const val I_BUF = 6
    const val I_RATE = 7
    const val I_CHANNELS = 8
    const val I_FORMAT = 9
    const val I_PERF = 10
    const val I_PRE = 11
    const val I_COUNT = 12

    // Layout of counters()'s out array; must match mbaudio.cpp.
    const val C_WRITTEN = 0
    const val C_READ = 1
    const val C_TS_POS = 2
    const val C_TS_NS = 3
    const val C_NOW = 4
    const val C_COUNT = 5

    /** Opens (not started) and writes one burst of silence; returns the handle, or 0 (see `info[I_ERROR/I_STAGE]`). */
    external fun open(sharing: Int, startBursts: Int, info: IntArray): Long
    external fun start(handle: Long): Int
    /**
     * T-287: suspends a started stream (writer thread, not real time): [stop] false = requestPause, true =
     * requestStop; waits up to [timeoutNs] for the state change. Returns the stream state ([STATE_PAUSED] ...) or a
     * negative AAudio error. [start] resumes it.
     */
    external fun pause(handle: Long, stop: Int, timeoutNs: Long): Int
    /** Frames written (may be short on timeout) or a negative AAudio error. */
    external fun write(handle: Long, data: ShortArray, frames: Int, timeoutNs: Long): Int
    /** CLOCK_MONOTONIC timestamp into `out[0]` (frame position) and `out[1]` (ns); returns an AAudio result. */
    external fun timestamp(handle: Long, out: LongArray): Int
    /**
     * T-101: AAudio's own counters and timestamp in one call into `out` (size >= [C_COUNT]): [C_WRITTEN]
     * (getFramesWritten), [C_READ] (getFramesRead), [C_TS_POS]/[C_TS_NS] (CLOCK_MONOTONIC timestamp, 0 unless the
     * result is [OK]) and [C_NOW] (CLOCK_MONOTONIC ns, read last). Returns the getTimestamp result.
     */
    external fun counters(handle: Long, out: LongArray): Int
    external fun xruns(handle: Long): Int
    external fun bufferSize(handle: Long): Int
    external fun setBufferSize(handle: Long, frames: Int): Int
    /** Stops and closes the stream and frees the handle; the handle must not be used again. */
    external fun close(handle: Long)
    /** AAudio_convertResultToText, for logs. */
    external fun errorText(code: Int): String
}
