package dev.matebridge.client.audio

/**
 * Client audio jitter buffer (decision 0011, PROTOCOL.md section 5): a preallocated ring of interleaved s16 frames,
 * at most [capacityFrames] (300 ms) deep. Pure Kotlin; every public method is synchronized because the control
 * reader thread writes and the audio writer thread reads. Callers that need several calls to be atomic (peek, resample,
 * consume) hold the monitor themselves (`synchronized(buffer) { ... }`).
 *
 * Positions are absolute frame counts of this buffer (silence fills included), never stream sample indexes; a ring
 * of anchors maps positions to host capture times for A/V alignment.
 *
 *  - A forward jump of `sample_index` (the host dropped audio) is filled with silence: the unread tail fades out,
 *    then silence (at most [maxGapFillFrames]), then the next packet fades in. No click.
 *  - Overflow drops the oldest frames with a short crossfade from the old read head into the new one.
 *  - Overlapping or old frames (sample_index behind the expected one) are discarded.
 *
 * Audio content is never logged.
 */
class AudioJitterBuffer(
    val capacityFrames: Int = DEFAULT_CAPACITY_FRAMES,
    private val channels: Int = 2,
    private val sampleRate: Int = 48_000,
    private val fadeFrames: Int = DEFAULT_FADE_FRAMES,
    private val maxGapFillFrames: Int = DEFAULT_MAX_GAP_FILL_FRAMES,
    anchorCapacity: Int = 128,
) {
    private val ring = ShortArray(capacityFrames * channels)
    private var writePos = 0L
    private var readPos = 0L

    /** Stream sample index expected next, or -1 before the first packet. */
    private var nextIndex = -1L

    /** Frames of the next written data that still get the fade-in after a gap. */
    private var fadeInLeft = 0

    private val anchorPos = LongArray(anchorCapacity)
    private val anchorCap = LongArray(anchorCapacity)
    private var anchorHead = 0 // next slot
    private var anchorCount = 0

    /** Counters for the per-second log line (events and frames). */
    var gapEvents = 0L; private set
    var gapFrames = 0L; private set
    var dropEvents = 0L; private set
    var dropFrames = 0L; private set
    var lateFrames = 0L; private set

    @get:Synchronized val level: Int get() = (writePos - readPos).toInt()

    @get:Synchronized val readPosition: Long get() = readPos

    @Synchronized fun reset() {
        writePos = 0; readPos = 0; nextIndex = -1; fadeInLeft = 0
        anchorHead = 0; anchorCount = 0
        gapEvents = 0; gapFrames = 0; dropEvents = 0; dropFrames = 0; lateFrames = 0
    }

    /**
     * Appends one packet of [frames] interleaved s16le frames from [pcm] (at [offset]). [sampleIndex] is the packet's
     * first frame in the stream, [captureUs] its host capture time.
     */
    @Synchronized fun write(sampleIndex: Long, captureUs: Long, pcm: ByteArray, frames: Int, offset: Int = 0) {
        require(frames >= 0 && offset >= 0 && offset + frames * channels * 2 <= pcm.size) { "bad pcm range" }
        if (frames == 0) return
        if (nextIndex < 0) nextIndex = sampleIndex
        var skip = 0
        var index = sampleIndex
        if (index < nextIndex) {
            val overlap = nextIndex - index
            if (overlap >= frames) { lateFrames += frames; return }
            skip = overlap.toInt()
            lateFrames += skip
            index += skip
        }
        val gap = index - nextIndex
        if (gap > 0) {
            gapEvents++
            gapFrames += gap
            fadeOutTail()
            appendSilence(minOf(gap, maxGapFillFrames.toLong()).toInt())
            fadeInLeft = fadeFrames
        }
        val n = frames - skip
        makeRoom(n)
        addAnchor(writePos, captureUs + skip * 1_000_000L / sampleRate)
        var src = offset + skip * channels * 2
        for (f in 0 until n) {
            val base = ((writePos + f) % capacityFrames).toInt() * channels
            val g = if (fadeInLeft > 0) (fadeFrames - fadeInLeft + 1).toFloat() / (fadeFrames + 1) else 1f
            for (c in 0 until channels) {
                val v = ((pcm[src].toInt() and 0xFF) or (pcm[src + 1].toInt() shl 8)).toShort()
                ring[base + c] = if (g < 1f) (v * g).toInt().toShort() else v
                src += 2
            }
            if (fadeInLeft > 0) fadeInLeft--
        }
        writePos += n
        nextIndex = index + n
    }

    /** Copies up to [frames] frames from the read head into [dst] without consuming them; returns the count copied. */
    @Synchronized fun peek(dst: ShortArray, frames: Int): Int {
        val n = minOf(frames, level, dst.size / channels)
        for (f in 0 until n) {
            val base = ((readPos + f) % capacityFrames).toInt() * channels
            for (c in 0 until channels) dst[f * channels + c] = ring[base + c]
        }
        return n
    }

    /** Consumes [frames] frames (clamped to the level). */
    @Synchronized fun consume(frames: Int) {
        readPos += minOf(frames.coerceAtLeast(0), level)
    }

    /** Hard resync: drops [frames] of the oldest frames with a crossfade ("fade out, skip, fade in"). */
    @Synchronized fun skipCrossfade(frames: Int) {
        val d = minOf(frames, level)
        if (d > 0) dropOldest(d)
    }

    /** Host capture time of the frame at the read head, or null before any packet. */
    @Synchronized fun readHeadCaptureUs(): Long? = captureTimeAt(readPos)

    /** Host capture time of the frame at absolute position [pos], extrapolated from the nearest anchor at or before it. */
    @Synchronized fun captureTimeAt(pos: Long): Long? {
        if (anchorCount == 0) return null
        var bestPos = Long.MIN_VALUE
        var bestCap = 0L
        var oldestPos = Long.MAX_VALUE
        var oldestCap = 0L
        for (i in 0 until anchorCount) {
            val slot = (anchorHead - 1 - i + anchorPos.size) % anchorPos.size
            val p = anchorPos[slot]
            if (p <= pos && p > bestPos) { bestPos = p; bestCap = anchorCap[slot] }
            if (p < oldestPos) { oldestPos = p; oldestCap = anchorCap[slot] }
        }
        if (bestPos == Long.MIN_VALUE) { bestPos = oldestPos; bestCap = oldestCap }
        return bestCap + (pos - bestPos) * 1_000_000L / sampleRate
    }

    private fun addAnchor(pos: Long, cap: Long) {
        anchorPos[anchorHead] = pos
        anchorCap[anchorHead] = cap
        anchorHead = (anchorHead + 1) % anchorPos.size
        if (anchorCount < anchorPos.size) anchorCount++
    }

    /** Drops the oldest frames so [incoming] more fit. */
    private fun makeRoom(incoming: Int) {
        val over = level + incoming - capacityFrames
        if (over > 0) dropOldest(minOf(over, level))
    }

    /** Linear fade to zero over the unread tail (at most [fadeFrames] frames). */
    private fun fadeOutTail() {
        val k = minOf(fadeFrames, level)
        for (i in 0 until k) {
            val base = ((writePos - k + i) % capacityFrames).toInt() * channels
            val g = (k - i).toFloat() / (k + 1)
            for (c in 0 until channels) ring[base + c] = (ring[base + c] * g).toInt().toShort()
        }
    }

    private fun appendSilence(frames: Int) {
        if (frames <= 0) return
        makeRoom(frames)
        for (f in 0 until frames) {
            val base = ((writePos + f) % capacityFrames).toInt() * channels
            for (c in 0 until channels) ring[base + c] = 0
        }
        writePos += frames
    }

    /**
     * Skips [d] frames (d <= level) at the read head. The first frames after the skip are crossfaded from the frames
     * the reader would have played next, so the output continues smoothly into the newer audio.
     */
    private fun dropOldest(d: Int) {
        val n = minOf(fadeFrames, level - d)
        for (i in 0 until n) {
            val a = ((readPos + i) % capacityFrames).toInt() * channels
            val b = ((readPos + d + i) % capacityFrames).toInt() * channels
            val w = (i + 1).toFloat() / (n + 1)
            for (c in 0 until channels) {
                ring[b + c] = (ring[a + c] * (1f - w) + ring[b + c] * w).toInt().toShort()
            }
        }
        readPos += d
        dropEvents++
        dropFrames += d
    }

    companion object {
        /** 300 ms at 48 kHz (decision 0011). */
        const val DEFAULT_CAPACITY_FRAMES = 14_400
        /** 3 ms. */
        const val DEFAULT_FADE_FRAMES = 144
        /** 100 ms: the host never holds more (PROTOCOL.md section 5); longer jumps are a time-axis shift, not silence. */
        const val DEFAULT_MAX_GAP_FILL_FRAMES = 4_800
    }
}
