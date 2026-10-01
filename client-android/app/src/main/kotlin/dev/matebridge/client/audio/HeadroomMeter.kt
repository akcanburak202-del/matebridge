package dev.matebridge.client.audio

/**
 * T-110: output headroom and write timing per stats window (pure; writer thread only).
 *
 * The writer calls [onWriteStart] just before each blocking write with the output's headroom (frames written - frames
 * read, [AudioSink.headroom]) and [onWriteEnd] when the write returns. A blocking write returns once its last frame is
 * in, so the ring is about full then; it is lowest just before the next write, which is where it is sampled.
 *
 * [onWriteStart]/[onWriteEnd] do not allocate (samples go into a preallocated array). [window] (once per stats second)
 * returns the window's figures and starts a new window.
 */
class HeadroomMeter(capacity: Int = DEFAULT_CAPACITY) {
    /** One window's figures; headroom fields are null when no headroom was known (AudioTrack). */
    data class Window(
        val writes: Int,
        val headroomMinFrames: Long?,
        val headroomP5Frames: Long?,
        /** Writes whose headroom was <= 0: the device read past what was written (an estimated underflow). */
        val underflowEst: Int,
        /** Longest time between two write starts (0 if fewer than two). */
        val gapMaxNs: Long,
        /** Longest time from a write's return to the next write's start: the writer's own delay. */
        val busyMaxNs: Long,
    )

    private val samples = IntArray(capacity)
    private val sorted = IntArray(capacity)
    private var n = 0
    private var writes = 0
    private var min = Long.MAX_VALUE
    private var known = 0
    private var underflow = 0
    private var gapMax = 0L
    private var busyMax = 0L
    private var lastStartNs = NONE
    private var lastEndNs = NONE

    /** A write is about to start at [nowNs] with [headroom] frames queued ([AudioSink.HEADROOM_UNKNOWN] if unknown). */
    fun onWriteStart(headroom: Long, nowNs: Long) {
        writes++
        if (lastStartNs != NONE) gapMax = maxOf(gapMax, nowNs - lastStartNs)
        if (lastEndNs != NONE) busyMax = maxOf(busyMax, nowNs - lastEndNs)
        lastStartNs = nowNs
        if (headroom == AudioSink.HEADROOM_UNKNOWN) return
        known++
        if (headroom < min) min = headroom
        if (headroom <= 0) underflow++
        if (n < samples.size) samples[n++] = headroom.coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
    }

    /** The write returned at [nowNs]. */
    fun onWriteEnd(nowNs: Long) {
        lastEndNs = nowNs
    }

    /** A new output: forget the previous write times (its gap is not the writer's) and start a new window. */
    fun reset() {
        lastStartNs = NONE
        lastEndNs = NONE
        clearWindow()
    }

    /** The current window's figures; starts a new window (write times carry over, so gaps across windows count). */
    fun window(): Window {
        val w = Window(
            writes = writes,
            headroomMinFrames = if (known > 0) min else null,
            headroomP5Frames = if (n > 0) p5() else null,
            underflowEst = underflow,
            gapMaxNs = gapMax,
            busyMaxNs = busyMax,
        )
        clearWindow()
        return w
    }

    private fun clearWindow() {
        n = 0
        writes = 0
        min = Long.MAX_VALUE
        known = 0
        underflow = 0
        gapMax = 0
        busyMax = 0
    }

    /** Nearest-rank 5th percentile of the stored samples (in-place insertion sort of a copy; ~200 per window). */
    private fun p5(): Long {
        System.arraycopy(samples, 0, sorted, 0, n)
        for (i in 1 until n) {
            val v = sorted[i]
            var j = i - 1
            while (j >= 0 && sorted[j] > v) {
                sorted[j + 1] = sorted[j]
                j--
            }
            sorted[j + 1] = v
        }
        val rank = (n * 5 + 99) / 100 // ceil(0.05 n), at least 1
        return sorted[rank - 1].toLong()
    }

    companion object {
        /** 2.5 s of 5 ms writes; a window has ~200. Beyond this only min/underflow/timing are kept. */
        const val DEFAULT_CAPACITY = 512
        private const val NONE = Long.MIN_VALUE
    }
}
