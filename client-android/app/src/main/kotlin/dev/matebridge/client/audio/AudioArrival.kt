package dev.matebridge.client.audio

/**
 * T-117: per-packet arrival timing of AUDIO_FRAME on the control reader (measurement only). Pure Kotlin.
 *
 * The control reader feeds every audio packet ([onPacket]) and closes every `read()` ([endRead]); the audio writer
 * takes a window once per second for its `ev=stats` line ([takeWindow]). Recording never allocates: windows are
 * preallocated arrays (a full window keeps exact maxima but stops adding percentile samples), and the gap details live
 * in one reused [Gap]. Reader and writer meet in short `synchronized` sections.
 *
 *  - arrival interval: read-return time of this packet minus the previous packet's (packets out of the same read
 *    have 0). An interval above [idleUs] counts as a paused stream and is not measured.
 *  - one-way delay (owd): arrival (read return, before decryption) + host-minus-client offset - `capture_time_us` -
 *    packet duration, i.e. the age of the packet's last frame when its bytes arrived. Needs the clock offset.
 *  - decrypt: the `RecordDecoder.next()` call that produced the packet (decryption plus decoding).
 *  - per read: audio packets out of one `read()` (bunching).
 *
 * An interval above [gapUs] marks a gap; [endRead] then reports it at most [maxGapLogsPerSec] times per second.
 */
class AudioArrivalMeter(
    capacity: Int = 512,
    private val gapUs: Long = 20_000,
    private val idleUs: Long = 1_000_000,
    private val maxGapLogsPerSec: Int = 5,
    private val sampleRate: Int = AudioStreamGate.SAMPLE_RATE,
) {
    /** One window's figures, in µs; null-like values are [NONE]. Reused by the caller. */
    class Window {
        var packets = 0
        var intervals = 0
        var intP50Us = NONE
        var intMaxUs = NONE
        var owdN = 0
        var owdP50Us = NONE
        var owdP95Us = NONE
        var owdMaxUs = NONE
        var perReadMax = 0
        var decryptMaxUs = NONE
        var gaps = 0

        /** The fields appended to the audio `ev=stats` line (docs/LOGGING.md); `-` = no data. */
        fun logFields(): String =
            "arr_int_ms_p50=${ms1(intP50Us)} arr_int_ms_max=${ms1(intMaxUs)} " +
                "owd_ms_p50=${ms1(owdP50Us)} owd_ms_p95=${ms1(owdP95Us)} owd_ms_max=${ms1(owdMaxUs)} " +
                "per_read_max=${if (packets > 0) perReadMax.toString() else "-"} decrypt_ms_max=${ms1(decryptMaxUs)} " +
                "arr_gaps=$gaps arr_n=$packets"
    }

    /** The last reported gap (valid right after [endRead] returned true, on the reader thread). */
    class Gap {
        var gapUs = 0L
        var owdUs = NONE
        var perRead = 0
        var decryptUs = 0L
        /** Gaps suppressed by the rate limit since the previous reported one. */
        var suppressed = 0
    }

    val gap = Gap()

    @Volatile private var offsetUs = NONE

    // Window (guarded by this).
    private val ints = LongArray(capacity)
    private var intN = 0
    private var intMax = NONE
    private val owds = LongArray(capacity)
    private var owdN = 0
    private var owdMax = NONE
    private var packets = 0
    private var perReadMax = 0
    private var decryptMax = NONE
    private var gaps = 0

    // Reader state (guarded by this).
    private var lastArrivalNs = NONE
    private var pendingGap = false
    private var pendingGapUs = 0L
    private var pendingOwdUs = NONE
    private var pendingDecryptUs = 0L
    private var limitStartNs = NONE
    private var limitCount = 0
    private var suppressed = 0

    // Writer scratch (guarded by this).
    private val scratch = LongArray(capacity)

    /** Host clock minus client clock from ClockSync, or null while unknown. */
    fun setOffset(hostMinusClientUs: Long?) {
        offsetUs = hostMinusClientUs ?: NONE
    }

    /** New connection or new stream: the next packet starts a fresh interval chain; the window is discarded. */
    @Synchronized fun reset() {
        lastArrivalNs = NONE
        pendingGap = false
        clearWindow()
    }

    /**
     * One AUDIO_FRAME. [readNs]: `read()` returned (before decryption); [decodeStartNs]/[decodedNs]: around the
     * decoder call that produced it. All `System.nanoTime()`. [captureHostUs] is the host time of its first frame.
     */
    @Synchronized fun onPacket(readNs: Long, decodeStartNs: Long, decodedNs: Long, captureHostUs: Long, frameCount: Int) {
        packets++
        val decUs = (decodedNs - decodeStartNs).coerceAtLeast(0) / 1000
        if (decryptMax == NONE || decUs > decryptMax) decryptMax = decUs

        val off = offsetUs
        val owd = if (off == NONE) NONE else readNs / 1000 + off - captureHostUs - frameCount * 1_000_000L / sampleRate
        if (owd != NONE) {
            if (owdN < owds.size) owds[owdN] = owd
            owdN++
            if (owdMax == NONE || owd > owdMax) owdMax = owd
        }

        val prev = lastArrivalNs
        lastArrivalNs = readNs
        if (prev == NONE) return
        val intUs = (readNs - prev) / 1000
        if (intUs < 0 || intUs > idleUs) return
        if (intN < ints.size) ints[intN] = intUs
        intN++
        if (intMax == NONE || intUs > intMax) intMax = intUs
        if (intUs > gapUs) {
            gaps++
            if (!pendingGap || intUs > pendingGapUs) {
                pendingGap = true
                pendingGapUs = intUs
                pendingOwdUs = owd
                pendingDecryptUs = decUs
            }
        }
    }

    /**
     * End of one `read()` that yielded [audioPackets] audio packets, at [nowNs]. True when a gap from this read should
     * be logged now (details in [gap]); false otherwise, including when the rate limit suppressed it.
     */
    @Synchronized fun endRead(audioPackets: Int, nowNs: Long): Boolean {
        if (audioPackets <= 0) return false
        if (audioPackets > perReadMax) perReadMax = audioPackets
        if (!pendingGap) return false
        pendingGap = false
        if (limitStartNs == NONE || nowNs - limitStartNs >= 1_000_000_000L) {
            limitStartNs = nowNs
            limitCount = 0
        }
        if (limitCount >= maxGapLogsPerSec) {
            suppressed++
            return false
        }
        limitCount++
        gap.gapUs = pendingGapUs
        gap.owdUs = pendingOwdUs
        gap.perRead = audioPackets
        gap.decryptUs = pendingDecryptUs
        gap.suppressed = suppressed
        suppressed = 0
        return true
    }

    /** Copies the current window into [out] and starts a new one. */
    @Synchronized fun takeWindow(out: Window) {
        out.packets = packets
        out.intervals = intN
        out.intMaxUs = intMax
        out.intP50Us = percentile(ints, minOf(intN, ints.size), 50)
        out.owdN = owdN
        out.owdMaxUs = owdMax
        val n = minOf(owdN, owds.size)
        out.owdP50Us = percentile(owds, n, 50)
        out.owdP95Us = percentile(owds, n, 95)
        out.perReadMax = perReadMax
        out.decryptMaxUs = decryptMax
        out.gaps = gaps
        clearWindow()
    }

    private fun clearWindow() {
        intN = 0; intMax = NONE
        owdN = 0; owdMax = NONE
        packets = 0; perReadMax = 0; decryptMax = NONE; gaps = 0
    }

    /** Nearest-rank percentile of the first [n] values of [src] (sorted in [scratch]); [NONE] when empty. */
    private fun percentile(src: LongArray, n: Int, p: Int): Long {
        if (n <= 0) return NONE
        System.arraycopy(src, 0, scratch, 0, n)
        java.util.Arrays.sort(scratch, 0, n)
        val rank = (p * n + 99) / 100 // ceil(p/100 * n)
        return scratch[(rank - 1).coerceIn(0, n - 1)]
    }

    companion object {
        /** "No value" marker for the µs fields. */
        const val NONE = Long.MIN_VALUE

        /** The meter the control reader feeds and the audio stats line reads (one control reader is current at a time). */
        val shared = AudioArrivalMeter()

        /** [us] as milliseconds with one decimal, signed; `-` for [NONE]. */
        fun ms1(us: Long): String {
            if (us == NONE) return "-"
            val neg = us < 0
            val tenths = (if (neg) -us else us) / 100
            return "${if (neg) "-" else ""}${tenths / 10}.${tenths % 10}"
        }
    }
}
